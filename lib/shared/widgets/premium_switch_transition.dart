import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

enum PremiumSwitchKind { business, personal, branch }

class PremiumSwitchSession {
  PremiumSwitchSession({
    required this.kind,
    required this.from,
    required this.to,
    required this.arabic,
  });

  final PremiumSwitchKind kind;
  final String from;
  final String to;
  final bool arabic;
  final covered = Completer<void>();
  final ready = Completer<void>();
  final finished = Completer<void>();
}

class PremiumSwitch {
  static final current = ValueNotifier<PremiumSwitchSession?>(null);
  static int _hosts = 0;

  static Future<void> run({
    required PremiumSwitchKind kind,
    required String from,
    required String to,
    required bool arabic,
    required Future<void> Function() action,
  }) async {
    if (current.value != null) return;
    if (_hosts == 0) {
      await action();
      return;
    }
    final session = PremiumSwitchSession(
      kind: kind,
      from: from,
      to: to,
      arabic: arabic,
    );
    current.value = session;
    Object? failure;
    StackTrace? trace;
    try {
      await session.covered.future;
      await action();
      await WidgetsBinding.instance.endOfFrame;
    } catch (e, st) {
      failure = e;
      trace = st;
    } finally {
      if (!session.ready.isCompleted) session.ready.complete();
      await session.finished.future;
      if (identical(current.value, session)) current.value = null;
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}

class PremiumSwitchHost extends StatefulWidget {
  const PremiumSwitchHost({super.key, required this.child});
  final Widget child;

  @override
  State<PremiumSwitchHost> createState() => _PremiumSwitchHostState();
}

class _PremiumSwitchHostState extends State<PremiumSwitchHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);
  PremiumSwitchSession? _session;
  bool _reduce = false;
  bool _waiting = false;
  Timer? _waitTimer;

  @override
  void initState() {
    super.initState();
    PremiumSwitch._hosts++;
    PremiumSwitch.current.addListener(_changed);
    unawaited(_PremiumSwitchSound.warm());
  }

  void _changed() {
    final session = PremiumSwitch.current.value;
    if (session == null || identical(session, _session)) return;
    setState(() {
      _session = session;
      _waiting = false;
    });
    _waitTimer?.cancel();
    _waitTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted &&
          identical(_session, session) &&
          !session.ready.isCompleted) {
        setState(() => _waiting = true);
      }
    });
    _reduce =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    unawaited(_perform(session));
  }

  Future<void> _perform(PremiumSwitchSession session) async {
    try {
      _motion.value = 0;
      await _motion.animateTo(
        .22,
        duration: Duration(milliseconds: _reduce ? 100 : 280),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      if (!session.covered.isCompleted) session.covered.complete();
      if (!_reduce) unawaited(_PremiumSwitchSound.play(session.kind));
      await _motion.animateTo(
        .74,
        duration: Duration(milliseconds: _reduce ? 80 : 950),
        curve: Curves.easeInOutCubic,
      );
      await session.ready.future;
      if (!mounted) return;
      await _motion.animateTo(
        1,
        duration: Duration(milliseconds: _reduce ? 100 : 430),
        curve: Curves.easeInOutCubic,
      );
    } on TickerCanceled {
      // Host disposal completes the hand-off below.
    } finally {
      _waitTimer?.cancel();
      if (!session.covered.isCompleted) session.covered.complete();
      if (!session.finished.isCompleted) session.finished.complete();
      if (mounted) setState(() => _session = null);
    }
  }

  @override
  void dispose() {
    PremiumSwitch._hosts--;
    _waitTimer?.cancel();
    PremiumSwitch.current.removeListener(_changed);
    final session = _session;
    if (session != null) {
      if (!session.covered.isCompleted) session.covered.complete();
      if (!session.finished.isCompleted) session.finished.complete();
    }
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      if (_session case final session?)
        Positioned.fill(
          child: PopScope(
            canPop: false,
            child: AbsorbPointer(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _motion,
                  builder: (context, _) => PremiumSwitchScene(
                    session: session,
                    progress: _motion.value,
                    reducedMotion: _reduce,
                    waiting: _waiting,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class PremiumSwitchScene extends StatelessWidget {
  const PremiumSwitchScene({
    super.key,
    required this.session,
    required this.progress,
    this.reducedMotion = false,
    this.waiting = false,
  });
  final PremiumSwitchSession session;
  final double progress;
  final bool reducedMotion;
  final bool waiting;

  double _phase(double a, double b) =>
      Curves.easeInOutCubic.transform(((progress - a) / (b - a)).clamp(0, 1));

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final personal = session.kind == PremiumSwitchKind.personal;
    final branch = session.kind == PremiumSwitchKind.branch;
    final accent = Color.lerp(
      AppColors.primaryLight,
      Colors.white,
      dark ? .72 : .64,
    )!;
    final base = Color.lerp(
      AppColors.primaryDark,
      Colors.black,
      dark
          ? .8
          : personal
          ? .5
          : branch
          ? .4
          : .28,
    )!;
    final cover = (progress / .18).clamp(0.0, 1.0);
    final reveal = _phase(.83, 1);
    final morph = reducedMotion ? 1.0 : _phase(.22, .72);
    final icon = personal
        ? Icons.account_balance_wallet_rounded
        : branch
        ? Icons.apartment_rounded
        : Icons.account_balance_rounded;
    final title = session.arabic
        ? branch
              ? 'وجهة جديدة، نفس النظام'
              : personal
              ? 'مساحتك الشخصية'
              : 'عالم أعمالك'
        : branch
        ? 'A new branch. One workspace.'
        : personal
        ? 'Your personal space'
        : 'Your business world';
    return Opacity(
      opacity: cover * (1 - reveal),
      child: Material(
        color: base,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _SwitchLightPainter(
                progress: reducedMotion ? .7 : progress,
                accent: accent,
                base: base,
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 440;
                  final width = math.min(constraints.maxWidth - 40, 420.0);
                  return Center(
                    child: SizedBox(
                      width: width,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'FYONA ERP',
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              color: accent,
                              fontSize: 13,
                              letterSpacing: 4,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: compact ? 8 : 24),
                          SizedBox(
                            height: compact ? 136 : 220,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                if (!reducedMotion)
                                  Transform(
                                    alignment: Alignment.center,
                                    transform: Matrix4.identity()
                                      ..setEntry(3, 2, .0018)
                                      ..translate(
                                        -width * .24 * morph,
                                        20 * morph,
                                      )
                                      ..rotateY(-.38 * morph)
                                      ..rotateZ(-.06 * morph)
                                      ..scale(1 - .14 * morph),
                                    child: Opacity(
                                      opacity: (1 - morph) * .85,
                                      child: _SwitchGlassCard(
                                        label: session.from,
                                        accent: Colors.white70,
                                        icon: branch
                                            ? Icons.apartment_rounded
                                            : personal
                                            ? Icons.account_balance_rounded
                                            : Icons
                                                  .account_balance_wallet_rounded,
                                        compact: compact,
                                      ),
                                    ),
                                  ),
                                Transform(
                                  alignment: Alignment.center,
                                  transform: Matrix4.identity()
                                    ..setEntry(3, 2, .0018)
                                    ..translate(
                                      width * .32 * (1 - morph),
                                      -18 * (1 - morph),
                                    )
                                    ..rotateY(.4 * (1 - morph))
                                    ..rotateZ(.04 * (1 - morph))
                                    ..scale(.88 + .12 * morph),
                                  child: Opacity(
                                    opacity: .2 + .8 * morph,
                                    child: _SwitchGlassCard(
                                      label: session.to,
                                      accent: accent,
                                      icon: icon,
                                      compact: compact,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: compact ? 8 : 24),
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            textDirection: session.arabic
                                ? TextDirection.rtl
                                : TextDirection.ltr,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: compact ? 15 : 21,
                              height: 1.45,
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Directionality(
                            textDirection: session.arabic
                                ? TextDirection.rtl
                                : TextDirection.ltr,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    session.from,
                                    key: const ValueKey('switch-route-from'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 11,
                                      color: Colors.white60,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Icon(
                                    session.arabic
                                        ? Icons.arrow_back_rounded
                                        : Icons.arrow_forward_rounded,
                                    key: const ValueKey('switch-route-arrow'),
                                    textDirection: TextDirection.ltr,
                                    size: 16,
                                    color: accent,
                                  ),
                                ),
                                Flexible(
                                  child: Text(
                                    session.to,
                                    key: const ValueKey('switch-route-to'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 11,
                                      color: accent,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: 112,
                            height: 3,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: progress.clamp(0, .85) / .85,
                                backgroundColor: Colors.white10,
                                valueColor: AlwaysStoppedAnimation(accent),
                              ),
                            ),
                          ),
                          if (waiting) ...[
                            const SizedBox(height: 10),
                            Text(
                              session.arabic
                                  ? 'جارٍ تجهيز بيانات الوجهة…'
                                  : 'Preparing your workspace…',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11,
                                color: Colors.white60,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchGlassCard extends StatelessWidget {
  const _SwitchGlassCard({
    required this.label,
    required this.accent,
    required this.icon,
    required this.compact,
  });
  final String label;
  final Color accent;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    width: compact ? 225 : 270,
    padding: EdgeInsets.all(compact ? 16 : 24),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          accent.withValues(alpha: .16),
          Colors.white.withValues(alpha: .025),
        ],
      ),
      border: Border.all(color: accent.withValues(alpha: .38)),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: .1),
          blurRadius: 45,
          spreadRadius: 2,
          offset: const Offset(0, 18),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: compact ? 30 : 42, color: accent),
            const Spacer(),
            Container(
              width: 28,
              height: 20,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: accent.withValues(alpha: .5)),
              ),
              // The card chip, without the sparkle mark.
            ),
          ],
        ),
        SizedBox(height: compact ? 12 : 25),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        if (!compact) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              for (final width in [52.0, 32.0, 20.0])
                Container(
                  width: width,
                  height: 3,
                  margin: const EdgeInsetsDirectional.only(end: 7),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ],
      ],
    ),
  );
}

class _SwitchLightPainter extends CustomPainter {
  const _SwitchLightPainter({
    required this.progress,
    required this.accent,
    required this.base,
  });
  final double progress;
  final Color accent;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * .5, size.height * .44);
    final glow = Rect.fromCircle(
      center: center,
      radius: size.shortestSide * .8,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [accent.withValues(alpha: .17), base.withValues(alpha: 0)],
        ).createShader(glow),
    );
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .025)
      ..strokeWidth = .6;
    for (var x = 0.0; x < size.width; x += 44) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 44) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 0; i < 4; i++) {
      final path = Path()
        ..moveTo(-size.width * .2, size.height * (.68 + i * .05))
        ..cubicTo(
          size.width * .25,
          size.height * (.15 + i * .035),
          size.width * .65,
          size.height * (.85 - i * .035),
          size.width * 1.2,
          size.height * (.26 + i * .05),
        );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == 0 ? 1.5 : .7
          ..shader = LinearGradient(
            colors: [
              accent.withValues(alpha: 0),
              accent.withValues(alpha: .22),
              accent.withValues(alpha: 0),
            ],
          ).createShader(Offset.zero & size),
      );
      final metric = path.computeMetrics().first;
      final at = ((progress * 1.5 + i * .17) % 1) * metric.length;
      final point = metric.getTangentForOffset(at)?.position;
      if (point != null) {
        canvas.drawCircle(
          point,
          3.5,
          Paint()
            ..color = accent.withValues(alpha: .6)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
        canvas.drawCircle(point, 1.4, Paint()..color = accent);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SwitchLightPainter old) =>
      old.progress != progress || old.base != base || old.accent != accent;
}

class _PremiumSwitchSound {
  static const _channel = MethodChannel('fyona/motion_audio');
  static final _section = AudioPlayer(playerId: 'fyona_motion_section');
  static final _branch = AudioPlayer(playerId: 'fyona_motion_branch');
  static Future<void>? _warming;

  static Future<void> warm() => _warming ??= _prepare();

  static Future<void> _prepare() async {
    try {
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
      for (final entry in [
        (_section, 'audio/motion_section.wav'),
        (_branch, 'audio/motion_branch.wav'),
      ]) {
        await entry.$1.setAudioContext(context);
        await entry.$1.setReleaseMode(ReleaseMode.stop);
        await entry.$1.setVolume(.2);
        await entry.$1.setSource(AssetSource(entry.$2));
      }
    } catch (_) {}
  }

  static Future<void> play(PremiumSwitchKind kind) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android &&
          await _channel.invokeMethod<bool>('canPlay') != true)
        return;
      await warm();
      final player = kind == PremiumSwitchKind.branch ? _branch : _section;
      await player.seek(Duration.zero);
      await player.resume();
    } catch (_) {}
  }
}
