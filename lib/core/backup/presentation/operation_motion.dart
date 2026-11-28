import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/app_localizations.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';

/// Which operation the motion tells the story of.
enum MotionKind { deviceRestore, cloudRestore, smartImport, backup }

/// What the work reports while it runs.
class MotionController {
  MotionController._(this._state);
  final ValueNotifier<_MotionState> _state;

  /// A new stage (its label) — with its own 0..1 progress when known.
  void stage(String label, [double? done]) {
    final s = _state.value;
    if (s.label != label) unawaited(_Sfx.tick());
    _state.value = s.copy(label: label, done: done, stages: s.label == label ? s.stages : s.stages + 1);
  }

  void progress(double done) => _state.value = _state.value.copy(done: done.clamp(0, 1).toDouble());
}

class _MotionState {
  const _MotionState({this.label = '', this.done, this.stages = 0, this.result = 0, this.message});
  final String label;
  final double? done;
  final int stages;

  /// 0 running · 1 done · -1 not completed
  final int result;
  final String? message;
  _MotionState copy({String? label, double? done, int? stages, int? result, String? message}) => _MotionState(
        label: label ?? this.label,
        done: done ?? this.done,
        stages: stages ?? this.stages,
        result: result ?? this.result,
        message: message ?? this.message,
      );
}

/// A full-screen motion that follows the REAL operation: progress comes from
/// the work itself, and the completion mark appears only once [work] has
/// returned (i.e. after the restore/import was verified). A failure shows
/// a calm "not completed" state with the reason and rethrows.
abstract final class OperationMotion {
  static Future<T> run<T>(
    BuildContext context, {
    required MotionKind kind,
    required Future<T> Function(MotionController c) work,
    String? doneText,
    String Function(Object error)? failureText,
  }) async {
    final state = ValueNotifier(const _MotionState());
    final c = MotionController._(state);
    final closed = Completer<void>();
    final nav = Navigator.of(context, rootNavigator: true);
    unawaited(nav.push(PageRouteBuilder<void>(
      opaque: true,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 380),
      pageBuilder: (_, a, _) => FadeTransition(
        opacity: a,
        child: PopScope(
          canPop: false,
          child: _MotionScreen(kind: kind, state: state, doneText: doneText, onClose: () {
            if (!closed.isCompleted) closed.complete();
          }),
        ),
      ),
    )));
    unawaited(_Sfx.start());
    try {
      final r = await work(c);
      state.value = state.value.copy(result: 1, done: 1);
      unawaited(_Sfx.done());
      // Closes by itself shortly after the check mark (or on "تم").
      final auto = Timer(const Duration(milliseconds: 2600), () {
        if (!closed.isCompleted) closed.complete();
      });
      await closed.future;
      auto.cancel();
      return r;
    } catch (e) {
      state.value = state.value.copy(result: -1, message: failureText?.call(e) ?? _t('motionFailed'));
      unawaited(_Sfx.fail());
      await closed.future;
      rethrow;
    } finally {
      if (nav.mounted && nav.canPop()) nav.pop();
      state.dispose();
    }
  }
}

class _MotionScreen extends StatefulWidget {
  const _MotionScreen({required this.kind, required this.state, required this.onClose, this.doneText});
  final MotionKind kind;
  final ValueNotifier<_MotionState> state;
  final VoidCallback onClose;
  final String? doneText;
  @override
  State<_MotionScreen> createState() => _MotionScreenState();
}

class _MotionScreenState extends State<_MotionScreen> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
  late final AnimationController _finish = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  double _shown = 0;
  Timer? _ease;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    // The ring follows the real progress smoothly (never jumps ahead).
    _ease = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final target = widget.state.value.done ?? (_shown + (0.92 - _shown) * 0.004);
      final next = _shown + (target - _shown) * 0.12;
      if ((next - _shown).abs() > 0.0005 && mounted) setState(() => _shown = next);
    });
  }

  void _onState() {
    final s = widget.state.value;
    if (s.result == 1 && !_finish.isAnimating && _finish.value == 0) {
      HapticFeedback.mediumImpact();
      _finish.forward();
    }
    if (s.result == -1 && _shake.value == 0) {
      HapticFeedback.heavyImpact();
      _shake.forward();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _ease?.cancel();
    _spin.dispose();
    _finish.dispose();
    _shake.dispose();
    super.dispose();
  }

  IconData get _icon => switch (widget.kind) {
        MotionKind.deviceRestore => Icons.phone_android_rounded,
        MotionKind.cloudRestore => Icons.cloud_download_rounded,
        MotionKind.smartImport => Icons.move_to_inbox_rounded,
        MotionKind.backup => Icons.shield_rounded,
      };

  String get _title => _t(switch (widget.kind) {
        MotionKind.deviceRestore => 'motionDeviceRestore',
        MotionKind.cloudRestore => 'motionCloudRestore',
        MotionKind.smartImport => 'motionImport',
        MotionKind.backup => 'motionBackup',
      });

  @override
  Widget build(BuildContext context) {
    final s = widget.state.value;
    final ok = s.result == 1, failed = s.result == -1;
    final accent = failed ? const Color(0xFFFFB74D) : const Color(0xFFFFD7DE);
    return Scaffold(
      backgroundColor: const Color(0xFF3A0711),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.25),
            radius: 1.1,
            colors: [Color(0xFF9E1B32), Color(0xFF5C0A1C), Color(0xFF26040B)],
            stops: [0, .55, 1],
          ),
        ),
        child: SafeArea(
          child: Stack(children: [
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_title,
                    style: const TextStyle(fontFamily: _font, fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(height: 28),
                AnimatedBuilder(
                  animation: Listenable.merge([_spin, _finish, _shake]),
                  builder: (_, _) {
                    final dx = sin(_shake.value * pi * 6) * 10 * (1 - _shake.value);
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: SizedBox(
                        width: 240,
                        height: 240,
                        child: CustomPaint(
                          painter: _OrbitPainter(
                            spin: _spin.value,
                            progress: ok ? 1 : _shown,
                            finish: _finish.value,
                            failed: failed,
                          ),
                          child: Center(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 350),
                              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                              child: ok
                                  ? _Check(key: const ValueKey('ok'), t: _finish.value)
                                  : failed
                                      ? const Icon(Icons.close_rounded, key: ValueKey('x'), size: 64, color: Color(0xFFFFB74D))
                                      : Column(key: const ValueKey('run'), mainAxisSize: MainAxisSize.min, children: [
                                          Icon(_icon, size: 42, color: Colors.white),
                                          const SizedBox(height: 6),
                                          Text('${(_shown * 100).floor()}%',
                                              style: const TextStyle(
                                                  fontFamily: _font, fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
                                        ]),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 26),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  child: Text(
                    ok ? (widget.doneText ?? _t('motionDone')) : failed ? (s.message ?? _t('motionFailed')) : s.label,
                    key: ValueKey('${s.result}|${s.label}|${s.message}'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w700, color: accent),
                  ),
                ),
                if (!ok && !failed) ...[
                  const SizedBox(height: 8),
                  Text(_t('motionKeepOpen'),
                      style: TextStyle(fontFamily: _font, fontSize: 12, color: Colors.white.withValues(alpha: .55))),
                ],
                if (ok || failed) ...[
                  const SizedBox(height: 22),
                  FilledButton(
                    key: const Key('motion-close'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF7A0F24),
                      padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 12),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: widget.onClose,
                    child: Text(_t(ok ? 'motionOk' : 'motionClose'),
                        style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({super.key, required this.t});
  final double t;
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(84, 84), painter: _CheckPainter(t));
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * .18, size.height * .54)
      ..lineTo(size.width * .42, size.height * .76)
      ..lineTo(size.width * .84, size.height * .28);
    final m = path.computeMetrics().first;
    canvas.drawPath(m.extractPath(0, m.length * Curves.easeOutCubic.transform(t.clamp(0, 1))), p);
  }

  @override
  bool shouldRepaint(_CheckPainter o) => o.t != t;
}

/// Rings, a progress arc and data particles streaming inward — they speed
/// up with the real progress; on completion they burst outward.
class _OrbitPainter extends CustomPainter {
  _OrbitPainter({required this.spin, required this.progress, required this.finish, required this.failed});
  final double spin, progress, finish;
  final bool failed;
  static final _seeds = List.generate(46, (i) => Random(i * 7919));
  static final _dots = [
    for (final r in _seeds) (r.nextDouble(), r.nextDouble() * 2 * pi, 1.2 + r.nextDouble() * 2.4, r.nextDouble()),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 14;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..color = Colors.white.withValues(alpha: .10);
    canvas.drawCircle(c, r, base);
    for (var i = 1; i <= 2; i++) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: .10 / i);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(spin * 2 * pi * (i.isEven ? -1 : 1));
      canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: r - 22.0 * i), 0, pi * 1.4, false, ring);
      canvas.restore();
    }
    // Data particles: spiral inward while working, burst outward on done.
    for (final (phase, angle, size0, hue) in _dots) {
      final f = (phase + spin * (0.6 + progress * 1.8)) % 1.0;
      final burst = Curves.easeOutCubic.transform(finish);
      final dist = finish > 0 ? r * (0.35 + burst * 1.1) : r * (1.15 - f * 0.85);
      final a = angle + spin * 2 * pi * 0.25 + f * 1.4;
      final o = c + Offset(cos(a), sin(a)) * dist;
      final alpha = finish > 0 ? (1 - burst) * .9 : (sin(f * pi) * .75);
      canvas.drawCircle(
          o,
          size0,
          Paint()
            ..color = (failed
                    ? const Color(0xFFFFB74D)
                    : Color.lerp(const Color(0xFFFFE3E8), const Color(0xFFFFC56B), hue)!)
                .withValues(alpha: alpha.clamp(0, 1).toDouble()));
    }
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: failed
            ? const [Color(0xFFFFB74D), Color(0xFFFF8A65)]
            : const [Color(0xFFFFFFFF), Color(0xFFFFC56B), Color(0xFFFFFFFF)],
        transform: GradientRotation(spin * 2 * pi),
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -pi / 2, 2 * pi * progress.clamp(0, 1), false, arc);
    if (finish > 0) {
      canvas.drawCircle(
          c,
          r * (0.55 + finish * 0.25),
          Paint()..color = Colors.white.withValues(alpha: (1 - finish) * .18));
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter o) => true;
}

/// Soft cues, always part of the motion (no in-app mute, owner's choice);
/// the phone's own silent/vibrate/DND mode still silences them.
abstract final class _Sfx {
  static AudioPlayer? _player;
  static const _gate = MethodChannel('fyona/motion_audio');

  static Future<bool> _canPlay() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return defaultTargetPlatform != TargetPlatform.linux;
    try {
      return await _gate.invokeMethod<bool>('canPlay') == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _play(String src, double volume) async {
    if (!await _canPlay()) return;
    try {
      final p = _player ??= AudioPlayer(playerId: 'fyona_operation_motion');
      await p.stop();
      await p.setVolume(volume);
      await p.play(AssetSource(src));
    } catch (_) {}
  }

  static Future<void> start() => _play('audio/restore_start.wav', .55);
  static Future<void> any(String src, double volume) => _play(src, volume);
  static Future<void> tick() => _play('audio/restore_tick.wav', .35);
  static Future<void> done() => _play('audio/restore_done.wav', .7);
  static Future<void> fail() => _play('audio/restore_fail.wav', .5);
}

/// A motion cue from outside the operation screen (e.g. Sara's scan in the
/// import window): same gate as the motion's own sounds.
Future<void> playMotionSound(String src, {double volume = .5}) => _Sfx.any(src, volume);
