// Reconciliation motions (2026-11):
//  - [ReconOpeningGate]: one short opening scene per reconciliation section
//    (financial: a ledger balance levelling; inventory: boxes landing on a
//    shelf and being counted), played while the page warms underneath, then
//    revealed with a soft fade. Back during the motion leaves the page.
//  - [ReconSettleMark]: the «balanced» moment after a settlement — two bars
//    (system / actual) converge, merge, and a check draws (< 1 s).
// Sounds: tools/recon_scene_sounds.py renders every cue from these keyframes.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../reports/presentation/widgets/report_scenes.dart'
    show ReportScenePalette;
import 'recon_results.dart' show kReconActual, kReconSystem;
import 'recon_widgets.dart' show reconBack;

enum ReconOpenScene { financial, inventory }

/// Whole opening choreography; keyframes below are fractions of it.
const Duration kReconOpenDuration = Duration(milliseconds: 1500);

/// The opening motion waits here until the page is ready.
const double kReconOpenHold = .80;

/// Fade from the scene to the page.
const Duration kReconRevealDuration = Duration(milliseconds: 260);

/// The settle («balanced») mark.
const Duration kReconSettleDuration = Duration(milliseconds: 900);

const String kReconSettleCue = 'audio/recon_settle.wav';

/// [0] starts with the motion, [1] when the hold is released.
List<String> reconOpenCues(ReconOpenScene scene) => switch (scene) {
  ReconOpenScene.financial => const [
    'audio/recon_open_financial.wav',
    'audio/recon_open_financial_end.wav',
  ],
  ReconOpenScene.inventory => const [
    'audio/recon_open_inventory.wav',
    'audio/recon_open_inventory_end.wav',
  ],
};

/// Every asset the reconciliation motions play (tests check they exist).
List<String> get reconMotionSoundAssets => [
  for (final s in ReconOpenScene.values) ...reconOpenCues(s),
  kReconSettleCue,
];

bool _reducedMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ||
    MediaQuery.accessibleNavigationOf(context);

// ─────────────────────────────────────────────────────────────── sound

/// Pre-loaded low-latency cue players with the app's motion-sound rules:
/// the `fyona/motion_audio` ringer/DND gate on Android, no audio focus,
/// mixes with other audio.
class ReconSceneSound {
  ReconSceneSound(this.assets);
  final List<String> assets;
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
      for (var i = 0; i < assets.length; i++) {
        if (_closed) return;
        final player = AudioPlayer();
        try {
          await player.setPlayerMode(PlayerMode.lowLatency);
          await player.setAudioContext(context);
          await player.setReleaseMode(ReleaseMode.stop);
          await player.setVolume(volume);
          await player.setSource(AssetSource(assets[i]));
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

  /// A cue that is not ready yet is skipped: silence beats a late sound.
  void fire(int index) {
    final player = _players[index];
    if (_closed || player == null) return;
    unawaited(player.resume().catchError((_) {}));
  }

  /// [linger] lets a ringing chime finish after the motion ends.
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
      Timer(const Duration(milliseconds: 1200), () => unawaited(release()));
    } else {
      await release();
    }
  }
}

// ─────────────────────────────────────────────────────────────── opening

/// Wraps a reconciliation section page: the scene covers it while it warms
/// (the page is built underneath from the first frame), then fades away.
/// With reduced motion the page shows at once, silently.
class ReconOpeningGate extends StatefulWidget {
  const ReconOpeningGate({
    super.key,
    required this.scene,
    required this.child,
    this.ready = true,
    this.duration = kReconOpenDuration,
  });
  final ReconOpenScene scene;
  final Widget child;

  /// `false` holds the motion before its final beat (data still loading).
  final bool ready;
  final Duration duration;

  @override
  State<ReconOpeningGate> createState() => _ReconOpeningGateState();
}

class _ReconOpeningGateState extends State<ReconOpeningGate>
    with TickerProviderStateMixin {
  late final AnimationController _timeline = AnimationController(vsync: this);
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: kReconRevealDuration,
  );
  final Completer<void> _ready = Completer<void>();
  ReconSceneSound? _sound;
  bool _started = false, _covered = true, _waiting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (_reducedMotion(context)) {
      _covered = false;
      return;
    }
    if (widget.ready) _ready.complete();
    unawaited(_run());
  }

  @override
  void didUpdateWidget(covariant ReconOpeningGate old) {
    super.didUpdateWidget(old);
    if (widget.ready && !_ready.isCompleted) _ready.complete();
  }

  Future<void> _run() async {
    final sound = _sound = ReconSceneSound(reconOpenCues(widget.scene));
    // The motion starts at once; the first cue joins if it loads within the
    // opening breath (its first beat is ≥ 300 ms in), otherwise it is skipped.
    unawaited(
      sound.prepare().then((_) {
        if (mounted && _timeline.value <= .06) sound.fire(0);
      }),
    );
    try {
      await _timeline
          .animateTo(
            kReconOpenHold,
            duration: widget.duration * kReconOpenHold,
            curve: Curves.linear,
          )
          .orCancel;
      if (!_ready.isCompleted) {
        setState(() => _waiting = true);
        await _ready.future;
        if (!mounted) return;
        setState(() => _waiting = false);
      }
      sound.fire(1);
      await _timeline
          .animateTo(1, duration: widget.duration * (1 - kReconOpenHold))
          .orCancel;
      await _reveal.forward().orCancel;
      if (!mounted) return;
      unawaited(sound.dispose(linger: true));
      _sound = null;
      setState(() => _covered = false);
    } on TickerCanceled {
      // Left (back) during the motion.
    }
  }

  @override
  void dispose() {
    _timeline.dispose();
    _reveal.dispose();
    unawaited(_sound?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The page keeps the same slot (index 0) before and after the reveal,
    // so its state is never rebuilt from scratch.
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_covered)
          AnimatedBuilder(
            animation: _reveal,
            builder: (context, child) => Opacity(
              opacity: 1 - Curves.easeOut.transform(_reveal.value),
              child: child,
            ),
            child: _OpeningStage(
              scene: widget.scene,
              timeline: _timeline,
              waiting: _waiting,
            ),
          ),
      ],
    );
  }
}

class _OpeningStage extends StatelessWidget {
  const _OpeningStage({
    required this.scene,
    required this.timeline,
    required this.waiting,
  });
  final ReconOpenScene scene;
  final Animation<double> timeline;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final palette = ReportScenePalette(dark);
    final financial = scene == ReconOpenScene.financial;
    return Scaffold(
      key: const ValueKey('recon-opening-scene'),
      backgroundColor: palette.background,
      body: SafeArea(
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = math.min(constraints.maxWidth - 32, 420.0);
                final height = math.min(
                  math.max(150.0, constraints.maxHeight * .46),
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
                          'FYONA  /  RECONCILIATION',
                          textDirection: TextDirection.ltr,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 10,
                            letterSpacing: 2.3,
                            color: palette.crimson,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ExcludeSemantics(
                          child: SizedBox(
                            width: width,
                            height: height,
                            child: RepaintBoundary(
                              child: AnimatedBuilder(
                                animation: timeline,
                                builder: (_, _) => CustomPaint(
                                  painter: ReconOpeningPainter(
                                    scene: scene,
                                    t: timeline.value,
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
                          l10n.translate(
                            financial ? 'reconOpenBankTitle' : 'reconOpenInvTitle',
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: palette.ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            l10n.translate(
                              waiting
                                  ? 'reconProcessing'
                                  : (financial
                                        ? 'reconOpenBankLine'
                                        : 'reconOpenInvLine'),
                            ),
                            key: ValueKey(waiting),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                              color: palette.mute,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            PositionedDirectional(
              top: 4,
              start: 4,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                color: palette.mute,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => reconBack(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────── easing

double _seg(double t, double a, double b) =>
    ((t - a) / (b - a)).clamp(0.0, 1.0).toDouble();
double _eoc(double x) => 1 - math.pow(1 - x, 3).toDouble();
double _eio(double x) =>
    x < .5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3).toDouble() / 2;
double _back(double x) {
  const c1 = 1.4, c3 = c1 + 1;
  return 1 + c3 * math.pow(x - 1, 3) + c1 * math.pow(x - 1, 2);
}

Paint _stroke(Color c, double w) => Paint()
  ..color = c
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

Path _partial(Path path, double f) {
  if (f <= 0) return Path();
  final out = Path();
  for (final m in path.computeMetrics()) {
    out.addPath(m.extractPath(0, m.length * f.clamp(0.0, 1.0)), Offset.zero);
  }
  return out;
}

/// Ring sweep + check, shared by the opening seals and the settle mark.
void _drawSeal(
  Canvas c,
  Offset center,
  double r,
  double ring,
  double check,
  Color color, {
  double width = 2.6,
}) {
  if (ring <= 0) return;
  c.drawCircle(
    center,
    r,
    Paint()..color = color.withValues(alpha: .10 * ring),
  );
  c.drawArc(
    Rect.fromCircle(center: center, radius: r),
    -math.pi / 2,
    2 * math.pi * ring,
    false,
    _stroke(color, width),
  );
  final tick = Path()
    ..moveTo(center.dx - r * .42, center.dy + r * .02)
    ..lineTo(center.dx - r * .10, center.dy + r * .32)
    ..lineTo(center.dx + r * .45, center.dy - r * .30);
  c.drawPath(_partial(tick, check), _stroke(color, width * 1.25));
}

// ─────────────────────────────────────────────────────────────── painter

/// Opening scene at timeline [t] (0…1) on a 320×240 grid, uniformly scaled
/// and centred, mirrored for RTL (it carries no text).
class ReconOpeningPainter extends CustomPainter {
  ReconOpeningPainter({
    required this.scene,
    required this.t,
    required this.dark,
    required this.rtl,
  }) : p = ReportScenePalette(dark);
  final ReconOpenScene scene;
  final double t;
  final bool dark, rtl;
  final ReportScenePalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min(size.width / 320, size.height / 240);
    canvas.save();
    canvas.translate(
      (size.width - 320 * k) / 2 + (rtl ? 320 * k : 0),
      (size.height - 240 * k) / 2,
    );
    canvas.scale(rtl ? -k : k, k);
    switch (scene) {
      case ReconOpenScene.financial:
        _financial(canvas);
      case ReconOpenScene.inventory:
        _inventory(canvas);
    }
    canvas.restore();
    // The seal is centred and never mirrored (a check reads the same way in
    // both directions).
    canvas.save();
    canvas.translate((size.width - 320 * k) / 2, (size.height - 240 * k) / 2);
    canvas.scale(k, k);
    _drawSeal(
      canvas,
      Offset(160, scene == ReconOpenScene.financial ? 58 : 40),
      17,
      _eoc(_seg(t, .80, .90)),
      _eio(_seg(t, .85, .96)),
      p.crimson,
    );
    canvas.restore();
  }

  // Ledger balance: post + beam draw, the «system» rows tip the left pan,
  // the «actual» rows bring the beam back to level, a seal draws above.
  void _financial(Canvas c) {
    const px = 160.0, baseY = 210.0, topY = 112.0, arm = 100.0;
    final post = _eoc(_seg(t, 0, .18));
    final beam = _eio(_seg(t, .08, .28));
    final pans = _eoc(_seg(t, .18, .32));
    final seal = _seg(t, .80, .92);

    // Base + post.
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: const Offset(px, baseY + 3),
          width: 84 * post,
          height: 6,
        ),
        const Radius.circular(3),
      ),
      Paint()..color = p.mute.withValues(alpha: .45 * post),
    );
    if (post > 0) {
      c.drawLine(
        const Offset(px, baseY),
        Offset(px, baseY - (baseY - topY) * post),
        _stroke(p.ink.withValues(alpha: .8), 3.4),
      );
    }

    // Row weights → beam angle (left heavier = left end down).
    double rows(double start) {
      var w = 0.0;
      for (var i = 0; i < 3; i++) {
        w += _eoc(_seg(t, start + .07 * i, start + .07 * i + .07));
      }
      return w;
    }

    final left = rows(.20), right = rows(.46);
    var angle = -(left - right) / 3 * .15;
    if (t > .67) {
      final x = t - .67;
      angle += .018 * math.exp(-x * 32) * math.sin(x * 70);
    }
    final cosA = math.cos(angle), sinA = math.sin(angle);
    final beamColor = Color.lerp(p.ink, p.crimson, seal)!;

    if (beam > 0) {
      final half = arm * beam;
      final a = Offset(px - half * cosA, topY - half * sinA);
      final b = Offset(px + half * cosA, topY + half * sinA);
      if (seal > 0) {
        c.drawLine(
          a,
          b,
          _stroke(p.crimson.withValues(alpha: .28 * seal), 9)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
      }
      c.drawLine(a, b, _stroke(beamColor, 3.2));
    }
    c.drawCircle(
      const Offset(px, topY),
      5.5 * post,
      Paint()..color = p.crimson,
    );

    // Pans hang from the beam ends; ledger rows drop into them.
    void pan(double side, double start, Color rowTone) {
      if (pans <= 0) return;
      final end = Offset(px + side * arm * cosA, topY + side * arm * sinA);
      final rim = end.dy + 50 * pans;
      final hang = _stroke(p.mute.withValues(alpha: .7 * pans), 1.2);
      c.drawLine(end, Offset(end.dx - 33, rim), hang);
      c.drawLine(end, Offset(end.dx + 33, rim), hang);
      final bowl = Path()
        ..moveTo(end.dx - 37, rim)
        ..quadraticBezierTo(end.dx, rim + 18, end.dx + 37, rim)
        ..close();
      c.drawPath(bowl, Paint()..color = p.soft.withValues(alpha: p.soft.a * pans));
      c.drawPath(bowl, _stroke(p.ink.withValues(alpha: .75 * pans), 1.8));
      for (var i = 0; i < 3; i++) {
        final r = _seg(t, start + .07 * i, start + .07 * i + .07);
        if (r <= 0) continue;
        final y = rim - 4 - i * 9 - 54 * (1 - _eoc(r));
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(end.dx, y), width: 34, height: 7),
          const Radius.circular(2.4),
        );
        final alpha = math.min(1.0, r * 3);
        c.drawRRect(
          rect,
          Paint()
            ..color = Color.lerp(
              rowTone,
              p.crimson,
              seal,
            )!.withValues(alpha: .88 * alpha),
        );
        c.drawLine(
          Offset(end.dx - 12, y),
          Offset(end.dx + (i.isEven ? 4 : 9), y),
          _stroke(p.card.withValues(alpha: .75 * alpha), 1.2),
        );
      }
    }

    pan(-1, .20, p.mute);
    pan(1, .46, p.crimson.withValues(alpha: .8));
  }

  // Shelf: frame draws, six boxes land, a scan passes and ticks each column,
  // a seal draws above the shelf.
  void _inventory(Canvas c) {
    const l = 76.0, r = 244.0, top = 74.0, mid = 140.0, bottom = 208.0;
    final frame = _eio(_seg(t, 0, .18));
    final seal = _seg(t, .80, .92);
    final line = _stroke(p.ink.withValues(alpha: .78), 2.6);
    if (frame > 0) {
      const cx = (l + r) / 2, half = (r - l) / 2;
      for (final y in const [mid, bottom]) {
        c.drawLine(
          Offset(cx - half * frame, y),
          Offset(cx + half * frame, y),
          line,
        );
      }
      final up = (bottom - top) * frame;
      c.drawLine(const Offset(l, bottom), Offset(l, bottom - up), line);
      c.drawLine(const Offset(r, bottom), Offset(r, bottom - up), line);
    }

    const cols = [112.0, 160.0, 208.0];
    final scan = _seg(t, .58, .78);
    final scanX = l + (r - l) * _eio(scan);
    for (var i = 0; i < 6; i++) {
      final shelfY = i < 3 ? bottom : mid;
      final h = i < 3 ? 36.0 : 32.0;
      final w = i < 3 ? 40.0 : 36.0;
      final cx = cols[i % 3];
      final d = _seg(t, .16 + .06 * i, .28 + .06 * i);
      if (d <= 0) continue;
      final y = shelfY - 1.5 - h - 64 * (1 - _back(d));
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - w / 2, y, w, h),
        const Radius.circular(4),
      );
      final a = math.min(1.0, d * 3);
      c.drawRRect(
        rect.shift(const Offset(0, 2)),
        Paint()
          ..color = p.shadow.withValues(alpha: p.shadow.a * a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      c.drawRRect(rect, Paint()..color = p.card.withValues(alpha: a));
      c.drawRRect(
        rect,
        _stroke(
          Color.lerp(p.mute, p.crimson, seal)!.withValues(alpha: .8 * a),
          1.3,
        ),
      );
      // Tape strip + label.
      c.drawLine(
        Offset(cx, y + 1),
        Offset(cx, y + h * .36),
        _stroke(p.crimson.withValues(alpha: .55 * a), 3),
      );
      final label = Rect.fromLTWH(cx - w * .32, y + h * .56, w * .64, h * .26);
      c.drawRRect(
        RRect.fromRectAndRadius(label, const Radius.circular(2)),
        Paint()..color = p.soft.withValues(alpha: math.min(1.0, p.soft.a * 2 * a)),
      );
      // Counted tick once the scan has passed this column.
      final tick = _eoc(_seg(scanX, cx - 6, cx + 14));
      if (tick > 0) {
        // Pre-mirrored in RTL so the canvas flip shows a normal check.
        double x(double f) =>
            label.left + label.width * (rtl ? 1 - f : f);
        final path = Path()
          ..moveTo(x(.28), label.center.dy)
          ..lineTo(x(.45), label.bottom - 1.5)
          ..lineTo(x(.74), label.top + 1.5);
        c.drawPath(_partial(path, tick), _stroke(p.crimson, 1.6));
      }
    }

    if (scan > 0 && scan < 1) {
      final glow = math.sin(math.pi * scan);
      c.drawLine(
        Offset(scanX, top - 6),
        Offset(scanX, bottom + 4),
        _stroke(p.crimson.withValues(alpha: .25 * glow), 10)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      c.drawLine(
        Offset(scanX, top - 6),
        Offset(scanX, bottom + 4),
        _stroke(p.crimson.withValues(alpha: .9 * glow), 1.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant ReconOpeningPainter old) =>
      old.t != t || old.dark != dark || old.rtl != rtl || old.scene != scene;
}

// ─────────────────────────────────────────────────────────────── settle

/// The «balanced» moment: the system bar and the actual bar converge to one
/// level, merge into a single line, and a sealed check draws (900 ms, one
/// soft cue — two tones gliding into unison, then a chime on the check).
class ReconSettleMark extends StatefulWidget {
  const ReconSettleMark({
    super.key,
    this.message,
    this.size = 168,
    this.duration = kReconSettleDuration,
    this.sound = true,
  });
  final String? message;
  final double size;
  final Duration duration;
  final bool sound;

  @override
  State<ReconSettleMark> createState() => _ReconSettleMarkState();
}

class _ReconSettleMarkState extends State<ReconSettleMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  ReconSceneSound? _sound;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (_reducedMotion(context)) {
      _controller.value = 1;
      return;
    }
    if (widget.sound) unawaited(_play());
    _controller.forward();
  }

  Future<void> _play() async {
    final sound = _sound = ReconSceneSound(const [kReconSettleCue]);
    await sound.prepare();
    // Skip a cue that would land well after the bars started moving.
    if (!mounted || _controller.value > .12) return;
    sound.fire(0);
  }

  @override
  void dispose() {
    _controller.dispose();
    unawaited(_sound?.dispose(linger: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final m = _eoc(_seg(t, .55, 1));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: ReconSettlePainter(t: t, dark: dark),
                  ),
                ),
              ),
            ),
            if (widget.message != null) ...[
              const SizedBox(height: 6),
              Opacity(
                opacity: m,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - m)),
                  child: Text(
                    widget.message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Settle mark at [t] (0…1) on a 200×200 grid.
class ReconSettlePainter extends CustomPainter {
  ReconSettlePainter({required this.t, required this.dark})
    : p = ReportScenePalette(dark);
  final double t;
  final bool dark;
  final ReportScenePalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min(size.width, size.height) / 200;
    canvas.save();
    canvas.translate(
      (size.width - 200 * k) / 2,
      (size.height - 200 * k) / 2,
    );
    canvas.scale(k);
    const c = Offset(100, 100), ringR = 48.0;
    final converge = _eio(_seg(t, 0, .38));
    final merge = _eoc(_seg(t, .34, .50));
    final ring = _eoc(_seg(t, .42, .72));
    final check = _eio(_seg(t, .56, .84));
    final halo = _seg(t, .76, .98);

    // Level guide: the target the two bars meet on.
    final guide = (1 - merge) * _seg(t, 0, .12);
    if (guide > 0) {
      canvas.drawLine(
        const Offset(28, 100),
        const Offset(172, 100),
        _stroke(p.hair.withValues(alpha: p.hair.a * guide), 1),
      );
    }

    // System bar (from above-left) and actual bar (from below-right).
    final barsAlpha = 1 - _seg(t, .44, .54);
    if (barsAlpha > 0) {
      final dx = ui.lerpDouble(56, 21, converge)!;
      final dy = ui.lerpDouble(26, 0, converge)!;
      final len = ui.lerpDouble(34, 42 + 30 * merge, converge)!;
      final thick = ui.lerpDouble(8, 4, merge)!;
      void bar(Offset at, Color tone) {
        final color = Color.lerp(tone, p.crimson, converge)!;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: at, width: len, height: thick),
            Radius.circular(thick / 2),
          ),
          Paint()..color = color.withValues(alpha: barsAlpha),
        );
      }

      bar(Offset(c.dx - dx, c.dy - dy), kReconSystem);
      bar(Offset(c.dx + dx, c.dy + dy), kReconActual);
    }

    // The single settled line flashes softly as the two merge.
    final flash = math.sin(math.pi * _seg(t, .34, .56));
    if (flash > 0) {
      canvas.drawLine(
        Offset(c.dx - 40 * merge, c.dy),
        Offset(c.dx + 40 * merge, c.dy),
        _stroke(p.crimson.withValues(alpha: .35 * flash), 8)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }

    if (halo > 0 && halo < 1) {
      canvas.drawCircle(
        c,
        ringR + 16 * _eoc(halo),
        _stroke(p.crimson.withValues(alpha: .28 * (1 - halo)), 2),
      );
    }
    _drawSeal(canvas, c, ringR, ring, check, p.crimson, width: 3.4);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ReconSettlePainter old) =>
      old.t != t || old.dark != dark;
}
