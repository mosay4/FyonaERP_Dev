import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../providers/locale_provider.dart';

/// Target locale of an in-flight language switch, or null when idle.
final languageTransitionProvider = StateProvider<Locale?>((ref) => null);

/// Request a language change with the globe transition. Falls back to an
/// instant switch if anything fails; duplicate requests are ignored.
Future<void> requestLanguageChange(WidgetRef ref, Locale target) async {
  try {
    if (ref.read(languageTransitionProvider) != null) return;
    final current = ref.read(localeProvider);
    if (current.languageCode == target.languageCode) return;
    ref.read(languageTransitionProvider.notifier).state = target;
  } catch (_) {
    try {
      await ref.read(localeProvider.notifier).setLocale(target);
    } catch (_) {}
  }
}

class LanguageTransitionOverlay extends ConsumerStatefulWidget {
  final Widget child;
  const LanguageTransitionOverlay({super.key, required this.child});

  @override
  ConsumerState<LanguageTransitionOverlay> createState() =>
      _LanguageTransitionOverlayState();
}

class _LanguageTransitionOverlayState
    extends ConsumerState<LanguageTransitionOverlay>
    with SingleTickerProviderStateMixin {
  // Long enough that the two flags are actually on screen for ~2s before the
  // switch lands: veil 0..12%, fully visible until 84%, locale applied at 1.4s
  // while the overlay still covers the rebuild.
  static const _total = Duration(milliseconds: 2600);
  static const _applyAt = Duration(milliseconds: 1400);

  AnimationController? _controller;
  Timer? _fallback;
  Locale? _running;
  bool _fromAr = true;

  @override
  void dispose() {
    _fallback?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _start(Locale target) {
    if (_running == target) return;
    _running = target;
    try {
      _fromAr = ref.read(localeProvider).languageCode != 'en';
    } catch (_) {
      _fromAr = target.languageCode != 'en';
    }
    _fallback?.cancel();
    _controller?.dispose();
    _controller = AnimationController(vsync: this, duration: _total);
    _fallback = Timer(const Duration(milliseconds: 3400), _finish);
    _controller!.forward().whenComplete(_finish);
    Future.delayed(_applyAt, () async {
      if (!mounted || _running != target) return;
      try {
        await ref.read(localeProvider.notifier).setLocale(target);
      } catch (_) {}
    });
  }

  void _finish() {
    if (_running == null) return;
    _running = null;
    _fallback?.cancel();
    try {
      ref.read(languageTransitionProvider.notifier).state = null;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(languageTransitionProvider);
    if (target == null) return widget.child;
    if (_running != target) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start(target);
      });
    }
    final controller = _controller;
    final toEnglish = target.languageCode == 'en';
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: AnimatedBuilder(
            animation: controller ?? _kStopped,
            builder: (_, __) {
              final v = controller?.value ?? 0.0;
              final veil = (v / 0.12).clamp(0.0, 1.0);
              final unVeil = ((1.0 - v) / 0.16).clamp(0.0, 1.0);
              final dim = (veil < 1.0 ? veil : unVeil).clamp(0.0, 1.0);
              return Opacity(
                opacity: dim.clamp(0.0, 1.0),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 7 * dim,
                    sigmaY: 7 * dim,
                  ),
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.2,
                        colors: [
                          Color(0xD9000000),
                          Color(0xF208080A),
                        ],
                      ),
                    ),
                    child: Center(
                      child: _TransitionCard(
                        progress: v,
                        fromAr: _fromAr,
                        toEnglish: toEnglish,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

const _kStopped = AlwaysStoppedAnimation<double>(0);

class _TransitionCard extends StatelessWidget {
  final double progress;
  final bool fromAr;
  final bool toEnglish;

  const _TransitionCard({
    required this.progress,
    required this.fromAr,
    required this.toEnglish,
  });

  @override
  Widget build(BuildContext context) {
    final outT = const Interval(0.05, 0.38, curve: Curves.easeIn)
        .transform(progress);
    final inT = const Interval(0.55, 0.85, curve: Curves.easeOutBack)
        .transform(progress);
    final enterT =
        const Interval(0.0, 0.18, curve: Curves.easeOut).transform(progress);
    final barT =
        const Interval(0.1, 0.9, curve: Curves.easeInOut).transform(progress);
    final leavingToLeft = fromAr;
    final l10n = AppLocalizations.of(context);
    return Opacity(
      opacity: enterT.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: 0.92 + 0.08 * enterT,
        child: Container(
          key: const ValueKey('lang_transition_card'),
          width: 300,
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1E1E22), Color(0xFF101013)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
                color: AppColors.primary.withAlpha(130), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withAlpha(70),
                blurRadius: 36,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: Colors.black.withAlpha(140),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey('lang_globe'),
                width: 164,
                height: 164,
                child: CustomPaint(
                  painter: _GlobePainter(rotation: progress),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 60,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _LangPill(
                      arabic: fromAr,
                      slide: leavingToLeft ? -84 * outT : 84 * outT,
                      opacity: 1 - outT,
                      scale: 1.0,
                    ),
                    const SizedBox(width: 12),
                    _SwapBadge(spin: progress),
                    const SizedBox(width: 12),
                    _LangPill(
                      arabic: !fromAr,
                      slide: leavingToLeft ? 84 * (1 - inT) : -84 * (1 - inT),
                      opacity: inT,
                      scale: 0.85 + 0.15 * inT,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // Explicit direction + no decoration: the caption must render
              // as plain text on every device, never with system underlines.
              Text(
                l10n.translate('languageSwitching'),
                textDirection:
                    toEnglish ? TextDirection.ltr : TextDirection.rtl,
                textAlign: TextAlign.center,
                softWrap: true,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                  decoration: TextDecoration.none,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(22),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: barT.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.primary,
                            AppColors.primary.withAlpha(170),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One language side: mini flag + language name in a glassy pill.
class _LangPill extends StatelessWidget {
  final bool arabic;
  final double slide;
  final double opacity;
  final double scale;

  const _LangPill({
    required this.arabic,
    required this.slide,
    required this.opacity,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(slide, 0),
        child: Transform.scale(
          scale: scale.clamp(0.0, 1.2),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withAlpha(45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CustomPaint(
                  painter:
                      arabic ? _SaudiFlagPainter() : _UsaFlagPainter(),
                  size: const Size(34, 24),
                ),
                const SizedBox(width: 7),
                Text(
                  arabic ? 'العربية' : 'English',
                  textDirection: arabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    decoration: TextDecoration.none,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The swap glyph between the pills: fades in, then does one full turn.
class _SwapBadge extends StatelessWidget {
  final double spin;
  const _SwapBadge({required this.spin});

  @override
  Widget build(BuildContext context) {
    final appear =
        const Interval(0.08, 0.25, curve: Curves.easeOut).transform(spin);
    final turn =
        const Interval(0.25, 0.85, curve: Curves.easeInOut).transform(spin);
    return Opacity(
      opacity: appear.clamp(0.0, 1.0),
      child: Transform.rotate(
        angle: turn * 6.28318,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withAlpha(30),
            border: Border.all(
                color: AppColors.primary.withAlpha(120), width: 1.2),
          ),
          child: const Icon(Icons.swap_horiz_rounded,
              size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

class _SaudiFlagPainter extends CustomPainter {
  /// The Shahada is painted as real text — there is no flag image asset in the
  /// bundle — fitted to ~86% of the flag width on a single line.
  static const String _shahada = 'لا إله إلا الله محمد رسول الله';

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );
    canvas.drawRRect(
        rrect, Paint()..color = const Color(0xFF006C35));
    canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withAlpha(90));

    var fontSize = size.height * 0.30;
    var text = _layout(fontSize, size.width * 0.86);
    while (text.didExceedMaxLines && fontSize > 5) {
      fontSize *= 0.9;
      text = _layout(fontSize, size.width * 0.86);
    }
    text.paint(
      canvas,
      Offset(
        (size.width - text.width) / 2,
        size.height * 0.34 - text.height / 2,
      ),
    );

    // The sword under the script: horizontal blade, tip on the left, hilt on
    // the right, exactly as the real flag draws it.
    final sword = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    final y = size.height * 0.70;
    canvas.drawLine(
        Offset(size.width * 0.24, y), Offset(size.width * 0.80, y), sword);
    final tip = Path()
      ..moveTo(size.width * 0.24, y)
      ..quadraticBezierTo(size.width * 0.18, y, size.width * 0.13,
          size.height * 0.61);
    canvas.drawPath(tip, sword);
    canvas.drawLine(
      Offset(size.width * 0.80, size.height * 0.63),
      Offset(size.width * 0.80, size.height * 0.77),
      sword,
    );
  }

  TextPainter _layout(double fontSize, double maxWidth) {
    return TextPainter(
      text: TextSpan(
        text: _shahada,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: fontSize,
          height: 1.0,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.center,
      maxLines: 1,
    )..layout(maxWidth: maxWidth);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _UsaFlagPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const stripes = 13;
    final stripeH = size.height / stripes;
    for (var i = 0; i < stripes; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * stripeH, size.width, stripeH + 0.5),
        Paint()
          ..color = i.isEven
              ? const Color(0xFFB31942)
              : Colors.white,
      );
    }
    final cantonW = size.width * 0.42;
    final cantonH = stripeH * 7;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, cantonW, cantonH),
      Paint()..color = const Color(0xFF0A3161),
    );
    final star = Paint()..color = Colors.white;
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        canvas.drawCircle(
          Offset(
            cantonW * (0.12 + 0.19 * col),
            cantonH * (0.14 + 0.24 * row),
          ),
          1.6,
          star,
        );
      }
    }
    final border = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );
    canvas.drawRRect(
        border,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withAlpha(90));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GlobePainter extends CustomPainter {
  /// 0..1 wrap progress of the spin.
  final double rotation;

  _GlobePainter({required this.rotation});

  static const List<List<List<double>>> _lands = [
    [
      [0.06, 0.18],
      [0.13, 0.10],
      [0.22, 0.12],
      [0.26, 0.20],
      [0.22, 0.30],
      [0.15, 0.33],
      [0.10, 0.28],
    ],
    [
      [0.30, 0.06],
      [0.35, 0.05],
      [0.36, 0.10],
      [0.31, 0.12],
    ],
    [
      [0.24, 0.38],
      [0.29, 0.36],
      [0.31, 0.45],
      [0.27, 0.58],
      [0.23, 0.62],
      [0.21, 0.50],
    ],
    [
      [0.47, 0.14],
      [0.54, 0.12],
      [0.56, 0.18],
      [0.50, 0.22],
      [0.46, 0.19],
    ],
    [
      [0.48, 0.32],
      [0.56, 0.30],
      [0.58, 0.40],
      [0.54, 0.52],
      [0.49, 0.55],
      [0.46, 0.42],
    ],
    [
      [0.56, 0.12],
      [0.70, 0.08],
      [0.85, 0.12],
      [0.92, 0.20],
      [0.85, 0.28],
      [0.70, 0.30],
      [0.60, 0.24],
    ],
    [
      [0.78, 0.58],
      [0.87, 0.56],
      [0.89, 0.62],
      [0.80, 0.65],
    ],
  ];

  static const List<List<double>> _deserts = [
    [0.47, 0.30],
    [0.55, 0.29],
    [0.56, 0.35],
    [0.48, 0.36],
    [0.57, 0.30],
    [0.62, 0.29],
    [0.63, 0.35],
    [0.58, 0.37],
  ];

  static const List<List<double>> _clouds = [
    [0.15, 0.25],
    [0.42, 0.18],
    [0.65, 0.38],
    [0.30, 0.55],
    [0.85, 0.48],
    [0.55, 0.62],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = side / 2 - 8;
    final square = Rect.fromCenter(center: center, width: radius * 2, height: radius * 2);

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius)));

    final ocean = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.4),
        radius: 1.1,
        colors: const [
          Color(0xFF2F7FC4),
          Color(0xFF123E7C),
          Color(0xFF0A1F4D),
        ],
      ).createShader(square);
    canvas.drawRect(square, ocean);

    final dx = -rotation.clamp(0.0, 1.0) * square.width;
    final land = Paint()..color = const Color(0xFF3F9E4D);
    final sand = Paint()..color = const Color(0xFFD9C27A);
    for (var copy = 0; copy < 3; copy++) {
      final ox = square.left + dx + copy * square.width;
      for (final poly in _lands) {
        final path = Path()
          ..moveTo(ox + poly[0][0] * square.width, poly[0][1] * square.height);
        for (var i = 1; i < poly.length; i++) {
          path.lineTo(ox + poly[i][0] * square.width, poly[i][1] * square.height);
        }
        path.close();
        canvas.drawPath(path, land);
      }
      final sandPath = Path()
        ..moveTo(ox + _deserts[0][0] * square.width, _deserts[0][1] * square.height);
      for (var i = 1; i < _deserts.length; i++) {
        sandPath.lineTo(
            ox + _deserts[i][0] * square.width, _deserts[i][1] * square.height);
      }
      sandPath.close();
      canvas.drawPath(sandPath, sand);
      final cloud = Paint()..color = Colors.white.withAlpha(70);
      for (final c in _clouds) {
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(
              ox + ((c[0] + rotation * 0.35) % 1.0) * square.width,
              c[1] * square.height,
            ),
            width: square.width * 0.10,
            height: square.height * 0.045,
          ),
          cloud,
        );
      }
    }

    final caps = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.center,
        colors: [Colors.white.withAlpha(235), Colors.white.withAlpha(0)],
      ).createShader(square);
    canvas.drawRect(
      Rect.fromLTWH(square.left, square.top, square.width, square.height * 0.10),
      caps,
    );
    final capsBottom = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.center,
        colors: [Colors.white.withAlpha(235), Colors.white.withAlpha(0)],
      ).createShader(square);
    canvas.drawRect(
      Rect.fromLTWH(square.left, square.bottom - square.height * 0.10,
          square.width, square.height * 0.10),
      capsBottom,
    );

    final limb = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.52,
        colors: const [Colors.transparent, Color(0x8C000014)],
        stops: const [0.72, 1.0],
      ).createShader(square);
    canvas.drawRect(square, limb);
    canvas.restore();

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = const Color(0xFF7FB8FF).withAlpha(70)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(center, radius + 2, glow);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFF7FB8FF).withAlpha(140);
    canvas.drawCircle(center, radius + 1, rim);

    final shine = Paint()..color = Colors.white.withAlpha(55);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.5);
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(-radius * 0.35, -radius * 0.42),
          width: radius * 0.55,
          height: radius * 0.28),
      shine,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlobePainter old) =>
      old.rotation != rotation;
}
