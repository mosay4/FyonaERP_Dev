// Report opening gate (v2, 2026-11): one precise vector motion per report,
// each with its own sound cues fired on the motion's keyframes.
//
// The previous motions are frozen in legacy/report_scenes_v1.dart (+ its own
// copy of the financial cinema). Flip [kUseLegacyReportScenes] to go back.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import 'legacy/report_scenes_v1.dart';

/// `true` restores the original (v1) report motions and sounds.
const bool kUseLegacyReportScenes = false;

enum ReportScene { sales, money, inventory, debts, overview }

/// Whole choreography; every keyframe below is a fraction of it.
const Duration kReportSceneDuration = Duration(milliseconds: 2200);

/// The motion pauses here until the report data is ready; the settle phase
/// (and its chime) only plays once the result is in hand.
const double kReportSceneHold = .80;

/// A sound cue: [asset] starts when the timeline reaches [at].
class ReportSceneCue {
  const ReportSceneCue(this.at, this.asset);
  final double at;
  final String asset;
}

/// Cue sheet per scene. Offsets inside each WAV were rendered from the same
/// keyframes (tools/report_scene_sounds.py), so starting a file
/// at [ReportSceneCue.at] keeps every tick, coin and thud on its frame.
List<ReportSceneCue> reportSceneCues(ReportScene scene) => switch (scene) {
  ReportScene.overview => const [
    ReportSceneCue(.26, 'audio/report_overview_tiles.wav'),
    ReportSceneCue(.50, 'audio/report_overview_ring.wav'),
    ReportSceneCue(.80, 'audio/report_overview_settle.wav'),
  ],
  ReportScene.sales => const [
    ReportSceneCue(.05, 'audio/report_sales_print.wav'),
    ReportSceneCue(.50, 'audio/report_sales_coins.wav'),
    ReportSceneCue(.80, 'audio/report_sales_settle.wav'),
  ],
  ReportScene.money => const [
    ReportSceneCue(.12, 'audio/report_money_dial.wav'),
    ReportSceneCue(.60, 'audio/report_money_flow.wav'),
    ReportSceneCue(.80, 'audio/report_money_settle.wav'),
  ],
  ReportScene.inventory => const [
    ReportSceneCue(.26, 'audio/report_inventory_boxes.wav'),
    ReportSceneCue(.62, 'audio/report_inventory_scan.wav'),
    ReportSceneCue(.80, 'audio/report_inventory_settle.wav'),
  ],
  ReportScene.debts => const [
    ReportSceneCue(.02, 'audio/report_debts_open.wav'),
    ReportSceneCue(.20, 'audio/report_debts_page.wav'),
    ReportSceneCue(.60, 'audio/report_debts_scale.wav'),
    ReportSceneCue(.80, 'audio/report_debts_settle.wav'),
  ],
};

class ReportSceneOverlay extends StatelessWidget {
  const ReportSceneOverlay({
    super.key,
    required this.scene,
    required this.sceneText,
    required this.processingText,
    required this.future,
    required this.onResult,
    required this.onError,
    this.duration = kReportSceneDuration,
  });
  final ReportScene scene;
  final String sceneText, processingText;
  final Future<dynamic> future;
  final void Function(BuildContext, dynamic) onResult;
  final void Function(BuildContext, Object) onError;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (kUseLegacyReportScenes) {
      return ReportSceneOverlayV1(
        scene: scene,
        sceneText: sceneText,
        processingText: processingText,
        future: future,
        onResult: onResult,
        onError: onError,
      );
    }
    return _ReportSceneGate(
      scene: scene,
      sceneText: sceneText,
      processingText: processingText,
      future: future,
      onResult: onResult,
      onError: onError,
      duration: duration,
    );
  }
}

// ─────────────────────────────────────────────────────────────── sound

/// Plays a scene's cues through short pre-loaded low-latency players, using
/// the same audio context and Android ringer/DND gate as the app's other
/// motion sounds (`fyona/motion_audio` → canPlay).
class ReportSceneSound {
  ReportSceneSound(this.scene);
  final ReportScene scene;
  static const _channel = MethodChannel('fyona/motion_audio');
  static const double volume = .32;
  final Map<int, AudioPlayer> _players = {};
  bool _closed = false;

  Future<void> prepare() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android &&
          await _channel.invokeMethod<bool>('canPlay') != true) {
        return;
      }
      final context = AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.ambient,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      );
      final cues = reportSceneCues(scene);
      for (var i = 0; i < cues.length; i++) {
        if (_closed) return;
        final player = AudioPlayer();
        try {
          await player.setPlayerMode(PlayerMode.lowLatency);
          await player.setAudioContext(context);
          await player.setReleaseMode(ReleaseMode.stop);
          await player.setVolume(volume);
          await player.setSource(AssetSource(cues[i].asset));
        } catch (_) {
          unawaited(player.dispose().catchError((_) {}));
          continue;
        }
        if (_closed) {
          unawaited(player.dispose().catchError((_) {}));
          return;
        }
        _players[i] = player;
      }
    } catch (_) {}
  }

  /// A cue whose player is not ready yet is skipped: silence is better than
  /// a sound that lands late.
  void fire(int index) {
    final player = _players[index];
    if (_closed || player == null) return;
    unawaited(player.resume().catchError((_) {}));
  }

  /// [linger] lets a chime that is still ringing finish after the gate
  /// closes on success; a cancelled gate stops at once.
  Future<void> dispose({bool linger = false}) async {
    _closed = true;
    if (_players.isEmpty) return;
    final players = List<AudioPlayer>.of(_players.values);
    _players.clear();
    Future<void> release() async {
      for (final p in players) {
        try {
          await p.stop();
          await p.dispose();
        } catch (_) {}
      }
    }

    if (linger) {
      Timer(const Duration(milliseconds: 900), () => unawaited(release()));
    } else {
      await release();
    }
  }
}

// ─────────────────────────────────────────────────────────────── gate

class _ReportSceneGate extends StatefulWidget {
  const _ReportSceneGate({
    required this.scene,
    required this.sceneText,
    required this.processingText,
    required this.future,
    required this.onResult,
    required this.onError,
    required this.duration,
  });
  final ReportScene scene;
  final String sceneText, processingText;
  final Future<dynamic> future;
  final void Function(BuildContext, dynamic) onResult;
  final void Function(BuildContext, Object) onError;
  final Duration duration;

  @override
  State<_ReportSceneGate> createState() => _ReportSceneGateState();
}

class _ReportSceneGateState extends State<_ReportSceneGate>
    with SingleTickerProviderStateMixin {
  /// Audio output latency compensation for cues before the hold point.
  static const _cueLeadMs = 40.0;
  late final AnimationController _controller = AnimationController(vsync: this)
    ..addListener(_onTick);
  ReportSceneSound? _sound;
  List<double> _cueAt = const [];
  int _generation = 0;
  bool _reduced = false, _done = false, _settled = false, _waiting = false;
  double _last = 0;
  dynamic _result;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_generation == 0) {
      _reduced =
          MediaQuery.disableAnimationsOf(context) ||
          MediaQuery.accessibleNavigationOf(context);
      _start();
    }
  }

  void _start() {
    final generation = ++_generation;
    _done = _settled = _waiting = false;
    _result = null;
    _last = 0;
    unawaited(_sound?.dispose());
    _sound = null;
    final lead = _cueLeadMs / math.max(1, widget.duration.inMilliseconds);
    _cueAt = [
      for (final cue in reportSceneCues(widget.scene))
        cue.at >= kReportSceneHold
            ? kReportSceneHold + 1e-4
            : math.max(1e-4, cue.at - lead),
    ];
    if (!_reduced) {
      _sound = ReportSceneSound(widget.scene);
      unawaited(_sound!.prepare());
    }
    _controller.value = 0;
    final ready = Completer<void>();

    unawaited(() async {
      try {
        final result = await widget.future;
        if (!mounted || generation != _generation) return;
        if (result == null) {
          throw StateError('The operation returned no result');
        }
        _result = result;
        _done = true;
        if (!ready.isCompleted) ready.complete();
      } catch (error) {
        if (!mounted || generation != _generation || _settled) return;
        _settled = true;
        _controller.stop();
        unawaited(_sound?.dispose());
        _sound = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) {
            widget.onError(context, error);
          }
        });
        setState(() {});
      }
    }());

    unawaited(() async {
      final total = _reduced
          ? const Duration(milliseconds: 250)
          : widget.duration;
      try {
        await _controller
            .animateTo(kReportSceneHold, duration: total * kReportSceneHold)
            .orCancel;
        if (!mounted || generation != _generation || _settled) return;
        if (!_done) setState(() => _waiting = true);
        await ready.future;
        if (!mounted || generation != _generation || _settled) return;
        if (_waiting) setState(() => _waiting = false);
        await _controller
            .animateTo(1, duration: total * (1 - kReportSceneHold))
            .orCancel;
        if (!mounted || generation != _generation || _settled) return;
        _settled = true;
        unawaited(_sound?.dispose(linger: true));
        _sound = null;
        widget.onResult(context, _result);
      } on TickerCanceled {
        // Disposed or restarted mid-motion.
      }
    }());
  }

  void _onTick() {
    final v = _controller.value;
    final sound = _sound;
    if (sound != null && v > _last) {
      for (var i = 0; i < _cueAt.length; i++) {
        if (_cueAt[i] > _last && _cueAt[i] <= v) sound.fire(i);
      }
    }
    _last = v;
  }

  @override
  void didUpdateWidget(covariant _ReportSceneGate old) {
    super.didUpdateWidget(old);
    if (old.future != widget.future || old.scene != widget.scene) _start();
  }

  @override
  void dispose() {
    _generation++;
    _controller.dispose();
    unawaited(_sound?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final palette = ReportScenePalette(dark);
    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(constraints.maxWidth - 32, 460.0);
            final height = math.min(
              math.max(150.0, constraints.maxHeight * .5),
              width * .75,
            );
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'FYONA  /  REPORTS',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10,
                        letterSpacing: 2.3,
                        color: dark
                            ? const Color(0xFFCEA5AD)
                            : AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ExcludeSemantics(
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: RepaintBoundary(
                          child: AnimatedBuilder(
                            animation: _controller,
                            builder: (_, _) => CustomPaint(
                              painter: ReportScenePainter(
                                scene: widget.scene,
                                t: _reduced ? 1 : _controller.value,
                                waiting: _waiting,
                                dark: dark,
                                rtl: rtl,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      widget.sceneText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Text(
                        _waiting
                            ? widget.processingText
                            : (rtl
                                  ? 'تحليل بياناتك الفعلية، بدقة.'
                                  : 'Analysing your actual records, precisely.'),
                        key: ValueKey(_waiting),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11.5,
                          color: dark
                              ? Colors.white60
                              : const Color(0xFF676169),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────── palette

class ReportScenePalette {
  const ReportScenePalette(this.dark);
  final bool dark;
  Color get background =>
      dark ? const Color(0xFF101013) : AppColors.surfaceLight;
  Color get ink => dark ? const Color(0xFFE8E4E7) : const Color(0xFF29242A);
  Color get mute => dark ? const Color(0xFF8E8A93) : const Color(0xFF9E99A1);
  Color get hair => dark ? const Color(0x2EFFFFFF) : const Color(0x2629242A);
  Color get card => dark ? const Color(0xFF1D1C22) : Colors.white;
  Color get soft => dark ? const Color(0x12FFFFFF) : const Color(0x0F29242A);
  Color get crimson => dark ? const Color(0xFFC8344F) : AppColors.primary;
  Color get shadow => dark ? const Color(0x66000000) : const Color(0x1F29242A);
}

// ─────────────────────────────────────────────────────────────── easing

double _seg(double t, double a, double b) =>
    ((t - a) / (b - a)).clamp(0.0, 1.0).toDouble();
double _eoc(double x) => 1 - math.pow(1 - x, 3).toDouble();
double _eoq(double x) => 1 - math.pow(1 - x, 4).toDouble();
double _eio(double x) =>
    x < .5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3).toDouble() / 2;
double _eios(double x) => -(math.cos(math.pi * x) - 1) / 2;
double _back(double x) {
  const c1 = 1.5, c3 = c1 + 1;
  return 1 + c3 * math.pow(x - 1, 3) + c1 * math.pow(x - 1, 2);
}

/// Inverse of [_eios]: the linear progress at which it reaches [y].
double _eiosInv(double y) =>
    math.acos(1 - 2 * y.clamp(0.0, 1.0).toDouble()) / math.pi;

// ─────────────────────────────────────────────────────────────── painter

/// Paints one report scene at timeline [t] (0…1) on a 320×240 design grid,
/// uniformly scaled and centred, mirrored for RTL.
class ReportScenePainter extends CustomPainter {
  ReportScenePainter({
    required this.scene,
    required this.t,
    this.waiting = false,
    this.dark = true,
    this.rtl = true,
  }) : p = ReportScenePalette(dark);

  final ReportScene scene;
  final double t;
  final bool waiting, dark, rtl;
  final ReportScenePalette p;

  static const designSize = Size(320, 240);

  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min(
      size.width / designSize.width,
      size.height / designSize.height,
    );
    if (k <= 0) return;
    canvas.save();
    if (rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.translate(
      (size.width - designSize.width * k) / 2,
      (size.height - designSize.height * k) / 2,
    );
    canvas.scale(k);
    final c = canvas;
    switch (scene) {
      case ReportScene.overview:
        _overview(c);
      case ReportScene.sales:
        _sales(c);
      case ReportScene.money:
        _money(c);
      case ReportScene.inventory:
        _inventory(c);
      case ReportScene.debts:
        _debts(c);
    }
    canvas.restore();
  }

  // ── primitives ──────────────────────────────────────────────────────

  Paint _fill(Color color, [double opacity = 1]) =>
      Paint()..color = color.withValues(alpha: color.a * opacity.clamp(0, 1));

  Paint _line(
    Color color,
    double width, {
    double opacity = 1,
    StrokeCap cap = StrokeCap.round,
  }) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = cap
    ..strokeJoin = StrokeJoin.round
    ..color = color.withValues(alpha: color.a * opacity.clamp(0, 1));

  void _shadow(Canvas c, RRect r, double opacity, {double dy = 3}) {
    if (opacity <= 0) return;
    c.drawRRect(
      r.shift(Offset(0, dy)),
      _fill(p.shadow, opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  void _seg2(Canvas c, Offset a, Offset b, double progress, Paint paint) {
    if (progress <= 0) return;
    c.drawLine(a, Offset.lerp(a, b, progress.clamp(0, 1))!, paint);
  }

  Path _partial(Path path, double progress) {
    final out = Path();
    if (progress <= 0) return out;
    for (final m in path.computeMetrics()) {
      out.addPath(
        m.extractPath(0, m.length * progress.clamp(0, 1)),
        Offset.zero,
      );
    }
    return out;
  }

  /// Expanding, fading ring.
  void _halo(Canvas c, Offset o, double r0, double r1, double q) {
    if (q <= 0 || q >= 1) return;
    final e = _eoc(q);
    c.drawCircle(
      o,
      r0 + (r1 - r0) * e,
      _line(p.crimson, 2 - e, opacity: .45 * (1 - q)),
    );
  }

  /// Crimson disc with a hand-drawn check; [grow] scales the disc in,
  /// [draw] traces the check.
  void _badge(Canvas c, Offset o, double r, double grow, double draw) {
    if (grow <= 0) return;
    final s = _back(grow).clamp(0.0, 1.2).toDouble();
    c.drawCircle(o, r * s + 2.2, _fill(p.background, math.min(1, grow * 2)));
    c.drawCircle(o, r * s, _fill(p.crimson, math.min(1, grow * 2)));
    if (draw <= 0) return;
    // A check mark is never mirrored: undo the RTL flip of the canvas.
    final m = rtl ? -1.0 : 1.0;
    final check = Path()
      ..moveTo(o.dx - .44 * r * m, o.dy + .02 * r)
      ..lineTo(o.dx - .13 * r * m, o.dy + .32 * r)
      ..lineTo(o.dx + .45 * r * m, o.dy - .30 * r);
    c.drawPath(
      _partial(check, draw),
      _line(Colors.white, math.max(1.3, r * .2)),
    );
  }

  /// A coin seen at a slight angle: rim (thickness) then face.
  void _coin(Canvas c, Offset o, double w, double h, double opacity) {
    if (opacity <= 0) return;
    final face = Rect.fromCenter(center: o, width: w, height: h);
    c.drawOval(
      face.shift(const Offset(0, 1.8)),
      _fill(_darker(p.crimson), opacity),
    );
    c.drawOval(face, _fill(p.crimson, opacity));
    c.drawOval(
      face.deflate(math.min(w, h) * .18),
      _line(Color.lerp(p.crimson, Colors.white, .45)!, .9, opacity: opacity),
    );
  }

  Color _darker(Color c) => Color.lerp(c, Colors.black, .35)!;

  // ── 1. Comprehensive: tiles assemble, fold into the overview ring, pulse

  void _overview(Canvas c) {
    const cx = 160.0, cy = 116.0;
    const centre = Offset(cx, cy);
    const tileW = 58.0, tileH = 44.0;
    const homes = [
      Offset(cx - 33, cy - 26),
      Offset(cx + 33, cy - 26),
      Offset(cx - 33, cy + 26),
      Offset(cx + 33, cy + 26),
    ];
    const dirs = [
      Offset(-1, -.8),
      Offset(1, -.8),
      Offset(-1, .8),
      Offset(1, .8),
    ];
    final gather = _eio(_seg(t, .50, .66));

    for (var i = 0; i < 4; i++) {
      final a = .04 + .07 * i;
      final q = _seg(t, a, a + .22);
      if (q <= 0 || gather >= 1) continue;
      final e = _eoq(q);
      final pop = .035 * math.sin(math.pi * _seg(t, a + .22, a + .27));
      final at = Offset.lerp(
        homes[i] + dirs[i] * (34 * (1 - e)),
        centre,
        gather * .55,
      )!;
      final s = (.9 + .1 * e) * (1 - .45 * gather) + pop;
      final o = math.min(1.0, q * 2.4) * (1 - gather);
      c.save();
      c.translate(at.dx, at.dy);
      c.scale(s);
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: tileW, height: tileH),
        const Radius.circular(8),
      );
      _shadow(c, r, o * .9);
      c.drawRRect(r, _fill(p.card, o));
      c.drawRRect(r, _line(p.hair, 1, opacity: o));
      _tileContent(c, i, o);
      c.restore();
    }

    // Ring: neutral track + four crimson quadrants with precise 6° gaps.
    const radius = 58.0;
    final ringRect = Rect.fromCircle(center: centre, radius: radius);
    final track = _seg(t, .48, .56);
    // The track fades once the quadrants are drawn, so the gaps read clean.
    final trackO = track * (1 - _seg(t, .70, .78));
    if (trackO > 0) {
      c.drawCircle(centre, radius, _line(p.hair, 7, opacity: trackO));
    }
    const tones = [1.0, .78, .58, .40];
    for (var i = 0; i < 4; i++) {
      final q = _eio(_seg(t, .52 + .035 * i, .64 + .035 * i));
      if (q <= 0) continue;
      const gap = 6 * math.pi / 180;
      c.drawArc(
        ringRect,
        -math.pi / 2 + i * math.pi / 2 + gap / 2,
        (math.pi / 2 - gap) * q,
        false,
        _line(p.crimson, 7, opacity: tones[i], cap: StrokeCap.butt),
      );
    }

    // Pulse line drawn through the centre, revealed along x.
    const ecg = [
      Offset(118, 0),
      Offset(144, 0),
      Offset(149, 5),
      Offset(155, -24),
      Offset(161, 14),
      Offset(166, 0),
      Offset(176, 0),
      Offset(180, -5),
      Offset(185, 0),
      Offset(202, 0),
    ];
    final reveal = _seg(t, .62, .80);
    final fade = 1 - _seg(t, .80, .86);
    if (reveal > 0 && fade > 0) {
      final xr = 118 + 84 * reveal;
      final path = Path()..moveTo(ecg[0].dx, cy + ecg[0].dy);
      var head = Offset(ecg[0].dx, cy + ecg[0].dy);
      for (var i = 1; i < ecg.length; i++) {
        final a = ecg[i - 1], b = ecg[i];
        if (xr >= b.dx) {
          head = Offset(b.dx, cy + b.dy);
          path.lineTo(head.dx, head.dy);
        } else {
          final f = (xr - a.dx) / (b.dx - a.dx);
          head = Offset(xr, cy + a.dy + (b.dy - a.dy) * f);
          path.lineTo(head.dx, head.dy);
          break;
        }
      }
      c.drawPath(path, _line(p.ink, 2, opacity: fade));
      if (reveal < 1) {
        c.drawCircle(head, 6, _fill(p.crimson, .22 * fade));
        c.drawCircle(head, 2.6, _fill(p.crimson, fade));
      }
    }

    // Settle: halo + centre badge.
    _halo(c, centre, radius + 4, radius + 24, _seg(t, .80, .98));
    _badge(c, centre, 15, _seg(t, .83, .93), _eio(_seg(t, .88, 1)));
  }

  void _tileContent(Canvas c, int i, double o) {
    final label = _line(p.mute, 2, opacity: o);
    switch (i) {
      case 0: // bars
        c.drawLine(const Offset(-19, -13), const Offset(-4, -13), label);
        const hs = [10.0, 16.0, 22.0];
        for (var b = 0; b < 3; b++) {
          final x = -17.0 + b * 11;
          c.drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTWH(x, 13 - hs[b], 7, hs[b]),
              topLeft: const Radius.circular(2),
              topRight: const Radius.circular(2),
            ),
            _fill(b == 2 ? p.crimson : p.mute, o * (b == 2 ? 1 : .55)),
          );
        }
      case 1: // sparkline
        c.drawLine(const Offset(-19, -13), const Offset(-4, -13), label);
        final spark = Path()
          ..moveTo(-19, 10)
          ..lineTo(-9, 3)
          ..lineTo(-2, 7)
          ..lineTo(8, -4)
          ..lineTo(18, -8);
        c.drawPath(spark, _line(p.crimson, 1.8, opacity: o));
        c.drawCircle(const Offset(18, -8), 2.2, _fill(p.crimson, o));
      case 2: // donut
        const d = Offset(-11, 1);
        c.drawCircle(d, 9.5, _line(p.hair, 3.6, opacity: o));
        c.drawArc(
          Rect.fromCircle(center: d, radius: 9.5),
          -math.pi / 2,
          math.pi * 4 / 3,
          false,
          _line(p.crimson, 3.6, opacity: o, cap: StrokeCap.butt),
        );
        c.drawLine(const Offset(5, -3), const Offset(19, -3), label);
        c.drawLine(const Offset(5, 5), const Offset(14, 5), label);
      default: // headline number
        c.drawLine(const Offset(-19, -13), const Offset(-4, -13), label);
        c.drawLine(
          const Offset(-19, 0),
          const Offset(8, 0),
          _line(p.ink, 4.4, opacity: o),
        );
        c.drawLine(const Offset(-19, 10), const Offset(-2, 10), label);
        final up = Path()
          ..moveTo(17, -5)
          ..lineTo(21.5, 2)
          ..lineTo(12.5, 2)
          ..close();
        c.drawPath(up, _fill(p.crimson, o));
    }
  }

  // ── 2. Sales & purchases: receipt prints, coin stacks rise, trend locks

  void _sales(Canvas c) {
    const slotY = 52.0, lip = 58.0;
    const px0 = 54.0, px1 = 130.0, pcx = (px0 + px1) / 2;
    const fullLen = 128.0;
    final appear = _eoc(_seg(t, 0, .08));
    final len = fullLen * _seg(t, .05, .45);
    final settle = _seg(t, .80, .92);

    // Paper (drawn first; the printer body hides its top).
    if (len > 0) {
      final edge = slotY + len;
      final paper = Path()..moveTo(px0, slotY);
      paper.lineTo(px0, edge - 3.5);
      const teeth = 10;
      const tw = (px1 - px0) / teeth;
      for (var i = 0; i < teeth; i++) {
        paper
          ..lineTo(px0 + tw * (i + .5), edge)
          ..lineTo(px0 + tw * (i + 1), edge - 3.5);
      }
      paper
        ..lineTo(px1, slotY)
        ..close();
      c.drawPath(
        paper.shift(const Offset(0, 2.5)),
        _fill(p.shadow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      c.drawPath(paper, _fill(p.card));
      c.drawPath(paper, _line(p.hair, 1.1));

      c.save();
      c.clipRect(const Rect.fromLTRB(px0, lip, px1, 240));
      double yOf(double u) => edge - u;
      // Total (crimson amount), separator, items, header.
      final ty = yOf(18);
      if (settle > 0) {
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(95, ty - 6.5, 127, ty + 6.5),
            const Radius.circular(6.5),
          ),
          _fill(p.crimson, .14 * _eoc(settle)),
        );
      }
      c.drawLine(Offset(62, ty), Offset(84, ty), _line(p.ink, 2.4));
      c.drawLine(Offset(100, ty), Offset(122, ty), _line(p.crimson, 3.2));
      final sy = yOf(30);
      for (var x = 62.0; x < 122; x += 6) {
        c.drawLine(
          Offset(x, sy),
          Offset(math.min(x + 3, 122), sy),
          _line(p.mute, 1.2),
        );
      }
      const items = [
        (44.0, 30.0, 12.0),
        (56.0, 24.0, 16.0),
        (68.0, 34.0, 10.0),
        (80.0, 20.0, 14.0),
      ];
      for (final (u, a, b) in items) {
        final y = yOf(u);
        c.drawLine(Offset(62, y), Offset(62 + a, y), _line(p.mute, 2));
        c.drawLine(Offset(122 - b, y), Offset(122, y), _line(p.ink, 2));
      }
      final hy = yOf(104);
      c.drawCircle(Offset(pcx, hy), 5, _line(p.crimson, 1.6));
      c.drawCircle(Offset(pcx, hy), 1.6, _fill(p.crimson));
      final ly = yOf(116);
      c.drawLine(
        Offset(pcx - 12, ly),
        Offset(pcx + 12, ly),
        _line(p.mute, 1.6),
      );
      c.restore();
    }

    // Printer body on top.
    if (appear > 0) {
      c.save();
      c.translate(0, -8 * (1 - appear));
      final body = RRect.fromRectAndRadius(
        const Rect.fromLTRB(44, 36, 140, 58),
        const Radius.circular(9),
      );
      _shadow(c, body, appear);
      c.drawRRect(body, _fill(p.card, appear));
      c.drawRRect(body, _line(p.ink, 1.8, opacity: appear));
      c.drawLine(
        const Offset(56, slotY),
        const Offset(128, slotY),
        _line(p.ink, 2.2, opacity: appear),
      );
      final printing = t > .05 && t < .45;
      c.drawCircle(
        const Offset(129, 44),
        2.2,
        _fill(p.crimson, appear * (printing ? 1 : .45)),
      );
      c.drawLine(
        const Offset(56, 44),
        const Offset(80, 44),
        _line(p.mute, 1.6, opacity: appear),
      );
      c.restore();
    }

    // Coin-stack bars.
    const base = 180.0;
    final axis = _eio(_seg(t, .30, .40));
    if (axis > 0) {
      _seg2(
        c,
        const Offset(164, base + 2.5),
        const Offset(286, base + 2.5),
        axis,
        _line(p.hair, 1.4),
      );
    }
    const xs = [170.0, 200.0, 230.0, 260.0];
    const hs = [40.0, 62.0, 54.0, 92.0];
    for (var i = 0; i < 4; i++) {
      final s = .34 + .06 * i;
      final rise = _eoc(_seg(t, s, s + .14));
      if (rise <= 0) continue;
      final h = hs[i] * rise;
      final top = base - h;
      final accent = i == 3;
      final bar = RRect.fromRectAndCorners(
        Rect.fromLTWH(xs[i], top, 20, h),
        topLeft: const Radius.circular(3),
        topRight: const Radius.circular(3),
      );
      c.drawRRect(bar, _fill(accent ? p.crimson : p.mute, accent ? 1 : .42));
      c.save();
      c.clipRRect(bar);
      for (var y = base - 8; y > top + 2; y -= 8) {
        c.drawLine(
          Offset(xs[i], y),
          Offset(xs[i] + 20, y),
          _line(p.background, 1, opacity: .55),
        );
      }
      c.restore();
      if (settle > 0 && accent) {
        c.drawRRect(
          bar.inflate(3 * _eoc(settle)),
          _line(p.crimson, 1.4, opacity: .5 * (1 - settle)),
        );
      }
      // Cap coin drops onto the finished stack.
      final drop = _seg(t, s + .10, s + .16);
      if (drop > 0) {
        final bounce = 2.5 * math.sin(math.pi * _seg(t, s + .16, s + .20));
        final finalTop = base - hs[i];
        final y = finalTop - 3.6 - 34 * (1 - drop * drop) - bounce;
        _coin(c, Offset(xs[i] + 10, y), 22, 7, math.min(1, drop * 3));
      }
    }

    // Trend line with an arrowhead that follows the exact tangent.
    final trendQ = _eio(_seg(t, .66, .80));
    if (trendQ > 0) {
      final pts = [
        for (var i = 0; i < 4; i++) Offset(xs[i] + 10, base - hs[i] - 16),
      ];
      final dir = pts[3] - pts[2];
      final tip = pts[3] + dir / dir.distance * 12;
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (final q in [...pts.skip(1), tip]) {
        path.lineTo(q.dx, q.dy);
      }
      final metric = path.computeMetrics().first;
      final at = metric.length * trendQ;
      c.drawPath(metric.extractPath(0, at), _line(p.crimson, 2.2));
      var walked = 0.0;
      for (var i = 0; i < 4; i++) {
        if (i > 0) walked += (pts[i] - pts[i - 1]).distance;
        if (walked <= at + .01) {
          c.drawCircle(pts[i], 3, _fill(p.background));
          c.drawCircle(pts[i], 3, _line(p.crimson, 1.6));
        }
      }
      final tan = metric.getTangentForOffset(at);
      if (tan != null) {
        final v = tan.vector;
        final n = Offset(-v.dy, v.dx);
        final head = Path()
          ..moveTo(tan.position.dx + v.dx * 4, tan.position.dy + v.dy * 4)
          ..lineTo(
            tan.position.dx - v.dx * 5 + n.dx * 4.5,
            tan.position.dy - v.dy * 5 + n.dy * 4.5,
          )
          ..lineTo(
            tan.position.dx - v.dx * 5 - n.dx * 4.5,
            tan.position.dy - v.dy * 5 - n.dy * 4.5,
          )
          ..close();
        c.drawPath(head, _fill(p.crimson));
        _halo(c, tip, 4, 20, _seg(t, .80, .98));
      }
    }
  }

  // ── 3. Money & accounts: the vault dial turns, coins flow between accounts

  void _money(Canvas c) {
    const centre = Offset(160, 112);
    const vr = 44.0;
    final settle = _seg(t, .80, .90);

    // Accounts.
    final slide = _eoc(_seg(t, .06, .28));
    final departed = [
      for (var i = 0; i < 3; i++) _eoc(_seg(t, .40 + .07 * i, .44 + .07 * i)),
    ];
    final arrived = [
      for (var i = 0; i < 3; i++) _eoc(_seg(t, .60 + .07 * i, .64 + .07 * i)),
    ];
    if (slide > 0) {
      // Wallet (sending account).
      c.save();
      c.translate(-22 * (1 - slide), 0);
      final w = RRect.fromRectAndRadius(
        const Rect.fromLTWH(22, 90, 64, 44),
        const Radius.circular(8),
      );
      _shadow(c, w, slide);
      c.drawRRect(w, _fill(p.card, slide));
      c.drawRRect(w, _line(p.ink, 1.6, opacity: slide));
      final flap = RRect.fromRectAndRadius(
        const Rect.fromLTWH(62, 103, 24, 18),
        const Radius.circular(5),
      );
      c.drawRRect(flap, _line(p.ink, 1.4, opacity: slide));
      c.drawCircle(const Offset(70, 112), 2.2, _fill(p.crimson, slide));
      final left = 26 * (1 - .22 * departed.fold(0.0, (a, b) => a + b));
      c.drawLine(
        const Offset(30, 124),
        const Offset(56, 124),
        _line(p.hair, 3, opacity: slide),
      );
      c.drawLine(
        const Offset(30, 124),
        Offset(30 + left, 124),
        _line(p.ink, 3, opacity: slide),
      );
      c.restore();
      // Bank card (receiving account).
      c.save();
      c.translate(22 * (1 - slide), 0);
      final b = RRect.fromRectAndRadius(
        const Rect.fromLTWH(234, 90, 64, 44),
        const Radius.circular(8),
      );
      _shadow(c, b, slide);
      c.drawRRect(b, _fill(p.card, slide));
      c.drawRRect(b, _line(p.ink, 1.6, opacity: slide));
      c.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(244, 99, 13, 10),
          const Radius.circular(2),
        ),
        _line(p.ink, 1.3, opacity: slide),
      );
      c.drawLine(
        const Offset(250.5, 99),
        const Offset(250.5, 109),
        _line(p.ink, 1, opacity: slide),
      );
      c.drawLine(
        const Offset(266, 104),
        const Offset(288, 104),
        _line(p.mute, 2, opacity: slide),
      );
      final right = 46 * (.25 + .25 * arrived.fold(0.0, (a, b) => a + b));
      c.drawLine(
        const Offset(244, 124),
        const Offset(290, 124),
        _line(p.hair, 3, opacity: slide),
      );
      c.drawLine(
        const Offset(244, 124),
        Offset(244 + right, 124),
        _line(p.crimson, 3, opacity: slide),
      );
      c.restore();
    }

    // Vault door.
    final draw = _eio(_seg(t, .03, .24));
    if (draw > 0) {
      final body = _seg(t, .03, .12);
      c.drawCircle(
        centre.translate(0, 3),
        vr,
        _fill(p.shadow, body)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      c.drawCircle(centre, vr, _fill(p.card, body));
      for (final y in [92.0, 122.0]) {
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(111, y, 7, 10),
            const Radius.circular(2),
          ),
          _fill(p.ink, body),
        );
      }
      final ringColor = Color.lerp(p.ink, p.crimson, _eoc(settle))!;
      c.drawArc(
        Rect.fromCircle(center: centre, radius: vr),
        -math.pi / 2,
        2 * math.pi * draw,
        false,
        _line(ringColor, 2.2),
      );
      c.drawCircle(centre, 33, _line(p.hair, 1.2, opacity: _seg(t, .14, .26)));
      final ticks = _seg(t, .16, .30);
      if (ticks > 0) {
        for (var i = 0; i < 24; i++) {
          final a = -math.pi / 2 + i * math.pi / 12;
          final u = Offset(math.cos(a), math.sin(a));
          final top = i == 0;
          c.drawLine(
            centre + u * 36.5,
            centre + u * (top ? 41 : 39.5),
            _line(top ? p.crimson : p.mute, top ? 1.8 : 1.1, opacity: ticks),
          );
        }
      }
      // Handle: four spokes, 15° detents, final pose square to the door.
      final hOpacity = _seg(t, .10, .18);
      if (hOpacity > 0) {
        final angle = (-120 + 120 * _eio(_seg(t, .12, .42))) * math.pi / 180;
        for (var i = 0; i < 4; i++) {
          final a = angle - math.pi / 2 + i * math.pi / 2;
          final u = Offset(math.cos(a), math.sin(a));
          c.drawLine(
            centre + u * 7,
            centre + u * 22,
            _line(p.ink, 2.6, opacity: hOpacity),
          );
          c.drawCircle(centre + u * 22, 2.9, _fill(p.ink, hOpacity));
        }
        final pulse = 1 + .22 * math.sin(math.pi * settle);
        c.drawCircle(centre, 7 * pulse, _fill(p.crimson, hOpacity));
        c.drawCircle(centre, 2.4, _fill(p.card, hOpacity));
      }
    }

    // Coins flow from the wallet over the vault into the bank account.
    const p0 = Offset(80, 100),
        p1 = Offset(116, 26),
        p2 = Offset(204, 26),
        p3 = Offset(240, 100);
    Offset bez(double u) {
      final v = 1 - u;
      return p0 * (v * v * v) +
          p1 * (3 * v * v * u) +
          p2 * (3 * v * u * u) +
          p3 * (u * u * u);
    }

    // Faint dotted route the money travels along.
    final route = _seg(t, .36, .44) * (1 - _seg(t, .80, .90));
    if (route > 0) {
      for (var d = 0; d <= 28; d++) {
        c.drawCircle(bez(d / 28), .9, _fill(p.mute, .7 * route));
      }
    }

    for (var i = 0; i < 3; i++) {
      final s = .40 + .07 * i;
      final q = _seg(t, s, s + .20);
      if (q <= 0 || q >= 1) continue;
      final u = _eios(q);
      final o = math.min(1.0, q / .12) * (q > .85 ? (1 - q) / .15 : 1);
      final shrink = q > .85 ? 1 - .35 * (q - .85) / .15 : 1.0;
      for (var g = 3; g >= 1; g--) {
        final gu = _eios((q - .035 * g).clamp(0.0, 1.0).toDouble());
        c.drawCircle(bez(gu), 6.5 - g, _fill(p.crimson, o * (.2 - .05 * g)));
      }
      _coin(c, bez(u), 14 * shrink, 14 * shrink, o);
    }

    _halo(c, centre, vr + 3, vr + 22, _seg(t, .80, .98));
  }

  // ── 4. Inventory: boxes drop onto shelves, a scan line checks every row

  static const _boxes = [
    // x, width, height, base y, accent
    (78.0, 48.0, 40.0, 178.0, true), // A
    (136.0, 40.0, 32.0, 178.0, false), // B
    (186.0, 56.0, 44.0, 178.0, false), // C
    (80.0, 44.0, 34.0, 114.0, false), // D
    (134.0, 52.0, 40.0, 114.0, true), // E
    (196.0, 46.0, 30.0, 114.0, false), // G
    (145.0, 30.0, 22.0, 74.0, false), // F (stacked on E)
  ];

  /// Scan-line rows: the check badges of a row pop together.
  static double _rowY(double base) =>
      base == 178 ? 157 : (base == 114 ? 94 : 61);

  void _inventory(Canvas c) {
    // Frame.
    final up = _eio(_seg(t, .02, .16));
    final board = _eio(_seg(t, .06, .20));
    if (up > 0) {
      for (final x in [64.0, 256.0]) {
        c.drawLine(Offset(x, 186), Offset(x, 186 - 146 * up), _line(p.ink, 4));
      }
    }
    if (board > 0) {
      for (final y in [114.0, 178.0]) {
        final half = 98 * board;
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(160 - half, y, 160 + half, y + 5),
            const Radius.circular(2.5),
          ),
          _fill(p.ink),
        );
      }
      c.drawLine(
        const Offset(48, 189),
        const Offset(272, 189),
        _line(p.hair, 1.2, opacity: board),
      );
    }

    final scanQ = _seg(t, .62, .80);
    for (var i = 0; i < _boxes.length; i++) {
      final (x, w, h, baseY, accent) = _boxes[i];
      final s = .14 + .055 * i, land = s + .12;
      final q = _seg(t, s, land);
      if (q <= 0) continue;
      final fall = -46 * (1 - q * q);
      final squash = math.sin(math.pi * _seg(t, land, land + .05));
      final sx = 1 + .04 * squash, sy = 1 - .06 * squash;
      final o = math.min(1.0, q * 4);
      c.save();
      c.translate(x + w / 2, baseY + fall);
      c.scale(sx, sy);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(-w / 2, -h, w, h),
        const Radius.circular(3),
      );
      if (q >= 1) _shadow(c, r, .6, dy: 1.5);
      c.drawRRect(r, _fill(p.card, o));
      if (accent) c.drawRRect(r, _fill(p.crimson, .12 * o));
      c.drawRRect(r, _line(accent ? p.crimson : p.ink, 1.5, opacity: o));
      final tape = w * .22;
      c.drawRect(
        Rect.fromLTWH(-tape / 2, -h, tape, h * .42),
        _fill(accent ? p.crimson : p.mute, (accent ? .35 : .28) * o),
      );
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-w / 2 + 5, -9, 12, 5),
          const Radius.circular(1),
        ),
        _line(p.mute, 1, opacity: o),
      );
      c.restore();

      // Check badge when the scan passes this row.
      final rowAt = .62 + .18 * _eiosInv((_rowY(baseY) - 40) / 144);
      final pop = _seg(t, rowAt, rowAt + .05);
      final pulse = .15 * math.sin(math.pi * _seg(t, .80, .90));
      if (pop > 0) {
        _badge(
          c,
          Offset(x + w, baseY - h),
          5.5 * (1 + pulse),
          pop,
          _seg(t, rowAt + .02, rowAt + .08),
        );
      }
    }

    // Scan line with a soft trailing glow.
    final fade = 1 - _seg(t, .80, .86);
    if (scanQ > 0 && fade > 0) {
      final y = 40 + 144 * _eios(scanQ);
      final glow = Rect.fromLTRB(56, y - 16, 264, y);
      c.drawRect(
        glow,
        Paint()
          ..shader = ui.Gradient.linear(glow.topCenter, glow.bottomCenter, [
            p.crimson.withValues(alpha: 0),
            p.crimson.withValues(alpha: .18 * fade),
          ]),
      );
      c.drawLine(
        Offset(56, y),
        Offset(264, y),
        _line(p.crimson, 1.6, opacity: fade),
      );
      c.drawCircle(Offset(56, y), 2.4, _fill(p.crimson, fade));
      c.drawCircle(Offset(264, y), 2.4, _fill(p.crimson, fade));
    }

    final glowQ = _seg(t, .80, 1);
    if (glowQ > 0) {
      for (final y in [114.0, 178.0]) {
        c.drawLine(
          Offset(62, y + 2.5),
          Offset(258, y + 2.5),
          _line(p.crimson, 2, opacity: .7 * math.sin(math.pi * glowQ)),
        );
      }
    }
  }

  // ── 5. Debts: the ledger opens, a page turns, entries write, scale levels

  void _debts(Canvas c) {
    const spine = 160.0, top = 104.0, bottom = 192.0, pw = 82.0;
    final appear = _eoc(_seg(t, 0, .06));
    final open = _eio(_seg(t, .02, .18));
    c.save();
    c.translate(0, 8 * (1 - appear));

    // Cover, right half then left half (opening from the spine).
    final cover = _darker(p.crimson);
    final coverR = RRect.fromRectAndCorners(
      const Rect.fromLTRB(spine, top - 4, spine + pw + 4, bottom + 4),
      topRight: const Radius.circular(5),
      bottomRight: const Radius.circular(5),
    );
    final coverL = RRect.fromRectAndCorners(
      const Rect.fromLTRB(spine - pw - 4, top - 4, spine, bottom + 4),
      topLeft: const Radius.circular(5),
      bottomLeft: const Radius.circular(5),
    );
    _shadow(c, coverR, appear);
    c.drawRRect(coverR, _fill(cover, appear));
    const rightPage = Rect.fromLTRB(spine, top, spine + pw, bottom);
    const leftPage = Rect.fromLTRB(spine - pw, top, spine, bottom);
    c.drawRect(rightPage, _fill(p.card, appear));
    c.drawRect(rightPage, _line(p.hair, 1, opacity: appear));
    if (open > 0) {
      c.save();
      c.translate(spine, 0);
      c.scale(open, 1);
      c.translate(-spine, 0);
      _shadow(c, coverL, appear);
      c.drawRRect(coverL, _fill(cover, appear));
      c.drawRect(leftPage, _fill(p.card, appear));
      c.drawRect(leftPage, _line(p.hair, 1, opacity: appear));
      if (t < .36) _oldLines(c, spine - pw, appear);
      c.restore();
    }
    // Spine shading.
    const sh = Rect.fromLTRB(spine - 10, top, spine + 10, bottom);
    c.drawRect(
      sh,
      Paint()
        ..shader = ui.Gradient.linear(
          sh.centerLeft,
          sh.centerRight,
          [
            p.shadow.withValues(alpha: 0),
            p.shadow.withValues(alpha: p.shadow.a * appear),
            p.shadow.withValues(alpha: 0),
          ],
          const [0, .5, 1],
        ),
    );

    // Page turn over [.20, .36]: projected width w·cosθ, free edge lifts.
    final flip = _eio(_seg(t, .20, .36));
    if (flip > 0 && flip < 1) {
      final th = math.pi * flip;
      final wp = pw * math.cos(th);
      final lift = 5 * math.sin(th);
      final face = Path()
        ..moveTo(spine, top)
        ..lineTo(spine + wp, top - lift)
        ..lineTo(spine + wp, bottom + lift)
        ..lineTo(spine, bottom)
        ..close();
      final shade = Color.lerp(p.card, p.mute, .22 * math.sin(th))!;
      c.drawPath(
        face.shift(const Offset(0, 2)),
        _fill(p.shadow, .6 * math.sin(th))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      c.drawPath(face, _fill(shade));
      c.drawPath(face, _line(p.hair, 1));
    } else if (flip <= 0 && appear > 0) {
      _oldLines(c, spine, appear);
    }

    // Fresh entries: owed to you (crimson amounts) | you owe (ink amounts).
    const labels = [34.0, 26.0, 38.0, 22.0, 30.0];
    const amounts = [14.0, 18.0, 12.0, 16.0, 20.0];
    for (var r = 0; r < 5; r++) {
      final y = 118.0 + 14 * r;
      for (final side in [0, 1]) {
        final q = _seg(
          t,
          .34 + .035 * r + .015 * side,
          .42 + .035 * r + .015 * side,
        );
        if (q <= 0) continue;
        final x0 = side == 0 ? spine - pw + 8 : spine + 8;
        final x1 = side == 0 ? spine - 8 : spine + pw - 8;
        _seg2(
          c,
          Offset(x0, y),
          Offset(x0 + labels[(r + side * 2) % 5], y),
          q * 1.6,
          _line(p.mute, 2),
        );
        _seg2(
          c,
          Offset(x1 - amounts[(r + side) % 5], y),
          Offset(x1, y),
          (q - .55) / .45,
          _line(side == 0 ? p.crimson : p.ink, 2.2),
        );
      }
    }
    c.restore();

    // Balance scale standing on the spine.
    const pivot = Offset(spine, 40);
    final post = _eoc(_seg(t, .40, .50));
    if (post <= 0) return;
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(spine - 11, top - 5, 22, 4),
        const Radius.circular(2),
      ),
      _fill(p.ink, post),
    );
    c.drawLine(
      const Offset(spine, top - 5),
      Offset(spine, top - 5 - (top - 5 - pivot.dy) * post),
      _line(p.ink, 2.6),
    );

    final beamQ = _eoc(_seg(t, .46, .54));
    if (beamQ > 0) {
      const amp = 9 * math.pi / 180;
      double theta = 0;
      if (t >= .60 && t < .64) {
        theta = -amp * _eoc(_seg(t, .60, .64));
      } else if (t >= .64 && t < .80) {
        final tau = _seg(t, .64, .80);
        theta =
            -amp *
            math.exp(-4 * tau) *
            math.cos(3 * math.pi * tau) *
            (1 - tau * tau);
      }
      final half = 75 * beamQ;
      final u = Offset(math.cos(theta), math.sin(theta));
      final endL = pivot - u * half, endR = pivot + u * half;
      final settle = _seg(t, .80, .90);
      c.drawLine(
        endL,
        endR,
        _line(
          Color.lerp(p.ink, p.crimson, .6 * math.sin(math.pi * settle))!,
          3.6,
        ),
      );

      final hang = _eoc(_seg(t, .48, .56));
      if (hang > 0) {
        for (final (end, left) in [(endL, true), (endR, false)]) {
          final rim = end.dy + 28 * hang;
          c.drawLine(
            end,
            Offset(end.dx - 17, rim),
            _line(p.mute, 1.2, opacity: hang),
          );
          c.drawLine(
            end,
            Offset(end.dx + 17, rim),
            _line(p.mute, 1.2, opacity: hang),
          );
          final pan = Path()
            ..moveTo(end.dx - 21, rim)
            ..quadraticBezierTo(end.dx, rim + 14, end.dx + 21, rim)
            ..close();
          c.drawPath(pan, _fill(p.card, hang));
          c.drawPath(pan, _line(p.ink, 1.8, opacity: hang));
          c.drawCircle(end, 2.4, _fill(p.ink, hang));
          // Weights drop in with gravity.
          final ws = left ? .54 : .58;
          final dq = _seg(t, ws, ws + .06);
          if (dq <= 0) continue;
          final dy = -30 * (1 - dq * dq);
          final o = math.min(1.0, dq * 3);
          if (left) {
            for (var k = 0; k < 3; k++) {
              _coin(c, Offset(end.dx, rim - 3.5 - 4.6 * k + dy), 20, 6, o);
            }
          } else {
            final slip = RRect.fromRectAndRadius(
              Rect.fromLTWH(end.dx - 11, rim - 15 + dy, 22, 14),
              const Radius.circular(2),
            );
            c.drawRRect(slip, _fill(p.card, o));
            c.drawRRect(slip, _line(p.ink, 1.3, opacity: o));
            c.drawLine(
              Offset(end.dx - 6, rim - 10 + dy),
              Offset(end.dx + 6, rim - 10 + dy),
              _line(p.mute, 1.4, opacity: o),
            );
            c.drawLine(
              Offset(end.dx - 6, rim - 5.5 + dy),
              Offset(end.dx + 2, rim - 5.5 + dy),
              _line(p.mute, 1.4, opacity: o),
            );
          }
        }
      }
      c.drawCircle(pivot, 5, _fill(p.crimson));
      c.drawCircle(pivot, 1.8, _fill(p.card));
    }

    // Settle: level halo + badge above the pivot.
    _halo(c, pivot, 6, 26, _seg(t, .80, .98));
    _badge(
      c,
      pivot.translate(0, -20),
      9,
      _seg(t, .82, .92),
      _eio(_seg(t, .87, 1)),
    );
  }

  /// Faint previous-entry lines on a page about to be turned.
  void _oldLines(Canvas c, double x0, double o) {
    for (var r = 0; r < 5; r++) {
      final y = 118.0 + 14 * r;
      c.drawLine(
        Offset(x0 + 8, y),
        Offset(x0 + 8 + 22 + 6.0 * (r % 3), y),
        _line(p.hair, 2, opacity: o),
      );
      c.drawLine(
        Offset(x0 + 82 - 22, y),
        Offset(x0 + 82 - 8, y),
        _line(p.hair, 2, opacity: o),
      );
    }
  }

  @override
  bool shouldRepaint(covariant ReportScenePainter old) =>
      old.t != t ||
      old.scene != scene ||
      old.dark != dark ||
      old.rtl != rtl ||
      old.waiting != waiting;
}
