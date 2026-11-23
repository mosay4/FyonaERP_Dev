import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import 'falcon_icon.dart';

/// ═════════════════════════════════════════════════════════════════════
/// FALCON MOTION SYSTEM
/// «تحليل → تجميع طاقة → حركة → قرار → هدوء»
///
/// One language shared by every layer: burgundy energy, soft silver light,
/// data particles, analysis arcs. All layers are paint-only (CustomPaint
/// with `repaint:` clocks), each isolated in a RepaintBoundary, paused when
/// the route is not visible (TickerMode) or the app is backgrounded, and
/// respecting the OS "disable animations" setting.
/// ═════════════════════════════════════════════════════════════════════



/// ═════════════════════════════════════════════════════════════════════
/// FALCON MOTION SYSTEM — AMBIENT WAVE
/// Single smooth energy wave rising from the composer area.
/// Intensity 0..1 (idle .35 → thinking 1.0 → streaming 1.0) drives the wave.
/// ═════════════════════════════════════════════════════════════════════

/// ── Ambient luminous field (Gemini-style motion, FYONA identity) ──
/// ONE living light source anchored to the composer (bottom center):
/// 2–3 broad soft fields only — a main burgundy bloom, a theme secondary
/// (dark shading in light / silver in dark) and a faint warm highlight —
/// plus a whisper of mist inside the glow. Organic sin/cos drift, no
/// visible boundaries, no geometric shapes, no discrete particles.
/// [intensity] 0..1 (idle .15 → typing .5 → thinking 1 → streaming .85)
/// is read every paint without rebuilding anything.
class FalconAmbientEnergy extends StatefulWidget {
  final Widget child;
  final ValueListenable<double> intensity;
  const FalconAmbientEnergy(
      {super.key, required this.child, required this.intensity});
  @override
  State<FalconAmbientEnergy> createState() => _FalconAmbientEnergyState();
}

class _FalconAmbientEnergyState extends State<FalconAmbientEnergy>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _clock =
      AnimationController(vsync: this, duration: const Duration(seconds: 12));
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    final on = _foreground &&
        TickerMode.of(context) &&
        !MediaQuery.disableAnimationsOf(context);
    if (on && !_clock.isAnimating) {
      _clock.repeat();
    } else if (!on && _clock.isAnimating) {
      _clock.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _EnergyPainter(
                clock: _clock,
                intensity: widget.intensity,
                dark: dark,
              ),
            ),
          ),
        ),
      ),
      widget.child,
    ]);
  }
}

class _EnergyPainter extends CustomPainter {
  final Animation<double> clock;
  final ValueListenable<double> intensity;
  final bool dark;
  _EnergyPainter(
      {required this.clock, required this.intensity, required this.dark})
      : super(repaint: Listenable.merge([clock, intensity]));

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value * math.pi * 2;
    final k = intensity.value.clamp(0, 1);
    final w = size.width, h = size.height;
    final burgundy = AppColors.primary;
    final deepRed = const Color(0xFF5C0A18);
    // LIGHT: burgundy energy + near-black shading for depth.
    // DARK: burgundy energy + translucent silver luminous field.
    final silver = Colors.white;
    final shading = dark ? silver : const Color(0xFF14060A);

    // Origin: composer area. The bloom starts small, spreads horizontally,
    // rises gradually, drifts its center, and fades as it climbs.
    final baseY = h * 1.04;
    final rise = h * (.08 + .17 * k) * (.75 + .25 * math.sin(t * .23));
    final rootCx = w * .5 + math.sin(t * .37 + 1.3) * w * .06 * (0.4 + .6 * k);

    // ── 1) MAIN field: a LIVING aurora — three overlapping soft blooms,
    // each with its own drift/breath phase so the union silhouette keeps
    // morphing (never a static stain, never discrete shapes).
    final blooms = [
      (dx: .00, f1: .50, f2: .41, ampX: .070, ampY: .045, rMul: 1.00, aMul: 1.00, ph: 0.0),
      (dx: -.13, f1: .33, f2: .29, ampX: .055, ampY: .060, rMul: 0.72, aMul: 0.85, ph: 2.1),
      (dx: .12, f1: .27, f2: .47, ampX: .065, ampY: .040, rMul: 0.62, aMul: 0.75, ph: 4.4),
    ];
    for (final b in blooms) {
      final cx = rootCx + w * b.dx +
          math.sin(t * b.f1 + b.ph) * w * b.ampX * (0.4 + .6 * k);
      final cy = baseY - rise -
          h * b.ampY * (1 + math.sin(t * b.f2 + b.ph * .7)) * .5;
      final r = w * (.40 + .30 * k) * b.rMul *
          (1 + .12 * math.sin(t * (.36 + b.f1 * .2) + b.ph));
      final a = ((16 + 58 * k) * b.aMul * (.82 + .18 * math.sin(t * .55 + b.ph)))
          .round();
      _ellipseGlow(
        canvas,
        Offset(cx, cy),
        r,
        r * .58,
        [burgundy.withAlpha(a), burgundy.withAlpha((a * .45).round()),
         Colors.transparent],
        BlendMode.srcOver,
      );
    }

    // ── 2) SECONDARY field — emerges gradually at high intensity
    // (dark depth in light theme / silver luminosity in dark theme),
    // with its own breathing so the two-layer field visibly exchanges.
    final secK = ((k - .45) / .55).clamp(0.0, 1.0);
    if (secK > 0) {
      final breathe2 = 1 + .14 * math.sin(t * .44 + 2.6);
      final secA = ((dark ? 24 : 17) * secK *
              (.8 + .2 * math.sin(t * .62 + .9)))
          .round();
      _ellipseGlow(
        canvas,
        Offset(rootCx + math.sin(t * .31 + 2.2) * w * .05,
            baseY - rise - h * .05),
        w * (.30 + .22 * k) * breathe2,
        w * (.30 + .22 * k) * breathe2 * .5,
        [shading.withAlpha(secA), Colors.transparent],
        dark ? BlendMode.screen : BlendMode.softLight,
      );
    }

    // ── 3) Warm highlight hugging the root (the "living ember") ──
    final hlA = ((12 + 30 * k) * (.75 + .25 * math.sin(t * .9 + 1.1))).round();
    _ellipseGlow(
      canvas,
      Offset(rootCx + math.cos(t * .43) * w * .03, baseY - h * .015),
      w * .24 * (1 + .10 * math.sin(t * .71)),
      w * .15 * (1 + .10 * math.sin(t * .71)),
      [deepRed.withAlpha(hlA), Colors.transparent],
      BlendMode.srcOver,
    );

    // ── Mist: a whisper of luminous grain INSIDE the glow (no bubbles) ──
    final rnd = math.Random(23);
    final mistK = ((k - .3) / .7).clamp(0.0, 1.0);
    for (var i = 0; i < 10; i++) {
      final sx = rnd.nextDouble();
      final sp = .05 + rnd.nextDouble() * .07;
      final phase = (clock.value * sp + rnd.nextDouble()) % 1;
      final lift = Curves.easeOutCubic.transform(phase);
      final x = rootCx + (sx - .5) * w * .5 +
          math.sin(t * (.4 + i * .09) + i * 1.9) * w * .02;
      final y = baseY - h * .22 * lift * (0.5 + .5 * k);
      final r = (3.0 + rnd.nextDouble() * 5.0) * (1 - lift * .35);
      final a = (math.sin(phase * math.pi) * 24 * mistK *
              (0.8 + .2 * math.sin(t * 1.1 + i)))
          .round();
      if (a <= 2) continue;
      canvas.drawCircle(
          Offset(x, y),
          r * 3.0,
          Paint()
            ..blendMode = BlendMode.screen
            ..shader = RadialGradient(colors: [
              silver.withAlpha(a),
              Colors.transparent,
            ]).createShader(Rect.fromCircle(center: Offset(x, y), radius: r * 3.0)));
    }
  }

  /// Soft elliptical glow (wider than tall) — the Gemini "spread" without
  /// any visible boundary. [mode] lifts silver on dark, deepens shading
  /// on light.
  void _ellipseGlow(Canvas canvas, Offset center, double rx, double ry,
      List<Color> colors, BlendMode mode) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1.0, ry / rx);
    final paint = Paint()
      ..blendMode = mode
      ..shader = RadialGradient(colors: colors)
          .createShader(Rect.fromCircle(center: Offset.zero, radius: rx));
    canvas.drawCircle(Offset.zero, rx, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EnergyPainter old) =>
      old.dark != dark || old.intensity != intensity;
}

/// ── Hero: the original logo with its light system (halo arcs, pulse wave,
/// 3D tilt). Never rotates/distorts the logo itself — arcs and tilt only.
class FalconHeroArt extends StatefulWidget {
  final double size;
  final Key? logoKey;
  const FalconHeroArt({super.key, this.size = 96, this.logoKey});
  @override
  State<FalconHeroArt> createState() => _HeroState();
}

class _HeroState extends State<FalconHeroArt>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _clock =
      AnimationController(vsync: this, duration: const Duration(seconds: 8));
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    final on = _foreground &&
        TickerMode.of(context) &&
        !MediaQuery.disableAnimationsOf(context);
    if (on && !_clock.isAnimating) {
      _clock.repeat();
    } else if (!on && _clock.isAnimating) {
      _clock.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    return RepaintBoundary(
      child: SizedBox.square(
        key: widget.logoKey,
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _clock,
          child: FalconMark(widget.size * .70),
          builder: (context, logo) {
            final t = _clock.value * math.pi * 2;
            return Stack(alignment: Alignment.center, children: [
              Positioned.fill(
                child: CustomPaint(painter: _HaloPainter(t: _clock.value)),
              ),
              Transform(
                transform: Matrix4.identity()
                  ..setEntry(3, 2, .0012)
                  ..rotateX(math.sin(t) * .03)
                  ..rotateY(math.cos(t) * .04),
                alignment: Alignment.center,
                child: Transform.translate(
                    offset: Offset(0, math.sin(t) * 2), child: logo),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  final double t;
  _HaloPainter({required this.t});
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide * .46;
    canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(colors: [
            AppColors.primary.withAlpha(46),
            AppColors.primary.withAlpha(7),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(center: center, radius: r)));
    // Multiple analysis arcs at different speeds/directions.
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: r * (1 - i * .085)),
          t * 2 * math.pi * (i.isEven ? 1 : -1) + i * 1.4,
          math.pi * (1.05 - i * .12),
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = i == 0 ? 1.7 : .9
            ..shader = SweepGradient(colors: [
              Colors.transparent,
              AppColors.primary.withAlpha(150),
              const Color(0xffc9a6d8).withAlpha(95),
              Colors.transparent,
            ]).createShader(Offset.zero & size));
    }
    // Expanding pulse wave.
    final wave = (t * 2) % 1;
    canvas.drawCircle(
        center,
        r * (.68 + wave * .32),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.primary
              .withAlpha(((1 - wave) * 70).round()));
    // Orbiting particles.
    for (var i = 0; i < 6; i++) {
      final a = t * 2 * math.pi * (.5 + i * .17) + i * 2.2;
      final rr = r * (.92 - (i % 3) * .06);
      canvas.drawCircle(
          center + Offset(math.cos(a), math.sin(a)) * rr,
          i.isEven ? 1.3 : 1,
          Paint()..color = AppColors.primary.withAlpha(120));
    }
  }

  @override
  bool shouldRepaint(covariant _HaloPainter old) => old.t != t;
}

/// ── Cinematic intro: logo center, ONE text slot, stages morph in place.
/// The page owns the 4s clock; the scene mirrors it for its text stages.
class FalconIntroScene extends StatelessWidget {
  final Animation<double> clock; // 0..1 over the intro duration
  final Key? logoKey;
  const FalconIntroScene(
      {super.key, required this.clock, this.logoKey});
  @override
  Widget build(BuildContext context) {
    const stageKeys = [
      'falconIntro1',
      'falconIntro2',
      'falconIntro3',
      'falconIntro4',
      'falconIntro5',
    ];
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(builder: (context, box) {
      final logoSize = math.min(200.0, box.maxWidth * .56);
      return Column(mainAxisSize: MainAxisSize.min, children: [
        FalconHeroArt(size: logoSize, logoKey: logoKey),
        const SizedBox(height: 24),
        SizedBox(
          height: 58,
          child: AnimatedBuilder(
            animation: clock,
            builder: (context, _) {
              final stage = (clock.value * stageKeys.length)
                  .floor()
                  .clamp(0, stageKeys.length - 1);
              // Per-stage local progress drives the morph.
              final local = (clock.value * stageKeys.length) - stage;
              return Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: (1 - local).clamp(0, 1),
                    child: Transform.translate(
                        offset: Offset(0, -8 * local),
                        child: Text(l10n.translate(stageKeys[stage]),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary
                                    .withAlpha((255 * (1 - local)).round())))),
                  ),
                  if (stage + 1 < stageKeys.length)
                    Opacity(
                      opacity: local.clamp(0, 1),
                      child: Transform.translate(
                          offset: Offset(0, 8 * (1 - local)),
                          child: Text(
                              l10n.translate(stageKeys[stage + 1]),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary
                                      .withAlpha((255 * local).round())))),
                    ),
                ],
              );
            },
          ),
        ),
      ]);
    });
  }
}

/// ── The logo flight: the SAME visual element travels from the intro
/// center to its header slot (scale + curved path + shrinking rings +
/// trailing light). Rendered as a page overlay during `flight`.
class FalconFlight extends StatelessWidget {
  final Animation<double> clock; // 0..1
  final Rect from; // hero rect (global)
  final Rect to; // header slot rect (global)
  const FalconFlight(
      {super.key, required this.clock, required this.from, required this.to});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: clock,
      builder: (context, _) {
        // ONE direct path: center → header slot (no intermediate stop).
        final t = Curves.easeInOutCubic.transform(clock.value);
        final fromC = from.center;
        final toC = to.center;
        final sizeLerp = from.width + (to.width - from.width) * t;
        final cur = Rect.fromCenter(
          center: Offset.lerp(fromC, toC, t)!,
          width: sizeLerp,
          height: sizeLerp,
        );
        return Stack(children: [
          Positioned(
            left: cur.left,
            top: cur.top,
            width: cur.width,
            height: cur.height,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _FlightPainter(t: clock.value),
                child: FalconMark(cur.width * .70),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _FlightPainter extends CustomPainter {
  final double t;
  _FlightPainter({required this.t});
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide * .55;
    final fade = (1 - t * .8).clamp(0, 1);
    // Rings contracting into the logo.
    for (var i = 0; i < 2; i++) {
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: r * (1 - t) * (1 + i * .4)),
          t * 6 * (i.isEven ? 1 : -1),
          math.pi * 1.2,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = AppColors.primary.withAlpha((150 * fade).round()));
    }
    // Soft glow that decreases as it lands.
    canvas.drawCircle(
        center,
        r * (1 + (1 - t) * .5),
        Paint()
          ..shader = RadialGradient(colors: [
            AppColors.primary.withAlpha((45 * fade).round()),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(center: center, radius: r)));
    // Short burgundy trail behind the movement.
    if (t > .05 && t < .92) {
      canvas.drawCircle(
          center + Offset(0, r * .8 * (1 - t)),
          2.5 * (1 - t),
          Paint()..color = AppColors.primary.withAlpha((90 * fade).round()));
    }
  }

  @override
  bool shouldRepaint(covariant _FlightPainter old) => old.t != t;
}

/// ── In-chat thinking experience: ONE breathing logo + phrases that
/// morph in the SAME slot (fade in → hold → soft fade → next). Inline in
/// the chat flow, directly below the user's latest message.
class FalconThinkingPhrases extends StatelessWidget {
  final Animation<double> clock; // page-driven stage clock (4s, repeats)
  final List<String> phrases;
  const FalconThinkingPhrases(
      {super.key, required this.clock, required this.phrases});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: 64,
          height: 64,
          child: Stack(alignment: Alignment.center, children: [
            AnimatedBuilder(
              animation: clock,
              builder: (context, _) {
                final t = clock.value * math.pi * 2;
                return CustomPaint(
                  size: const Size.square(64),
                  painter: _ThinkPainter(t: t),
                );
              },
            ),
            AnimatedBuilder(
              animation: clock,
              builder: (context, child) {
                // Very subtle breathing (±3.5%) — alive, never zoomy.
                final sc = 1 + .035 * math.sin(clock.value * math.pi * 2);
                return Transform.scale(scale: sc, child: child);
              },
              child: const FalconMark(38),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AnimatedBuilder(
            animation: clock,
            builder: (context, _) {
              final n = phrases.length;
              if (n == 0) return const SizedBox.shrink();
              final pos = (clock.value * n) % n;
              final stage = pos.floor().clamp(0, n - 1);
              final local = pos - stage;
              // Fade in → hold → soft fade → next phrase, same slot.
              final out = local > .7 ? (local - .7) / .3 : 0.0;
              final cur = phrases[stage];
              final nxt = phrases[(stage + 1) % n];
              Widget phrase(String s, double opacity, double dy) => Opacity(
                    opacity: opacity.clamp(0, 1),
                    child: Transform.translate(
                        offset: Offset(0, dy),
                        child: Text(s,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textSecondary))),
                  );
              return Stack(
                alignment: AlignmentDirectional.centerStart,
                children: [
                  phrase(cur, 1 - out, -8 * out),
                  if (out > 0) phrase(nxt, out, 8 * (1 - out)),
                ],
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _ThinkPainter extends CustomPainter {
  final double t;
  _ThinkPainter({required this.t});
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * .46;
    // Soft burgundy halo — breathes with the clock (alpha + radius).
    final haloA = 14 + 12 * math.sin(t * 1.3).abs();
    final haloR = r * (1.02 + .05 * math.sin(t * .8));
    canvas.drawCircle(
        c,
        haloR,
        Paint()
          ..shader = RadialGradient(colors: [
            AppColors.primary.withAlpha(haloA.round()),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(center: c, radius: haloR)));
    // Orbit arcs.
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        t,
        math.pi * .9,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.primary.withAlpha(110));
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * .8),
        -t * 1.4,
        math.pi * .6,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8
          ..color = AppColors.primary.withAlpha(70));
    // Tiny orbiting specks (very few, very soft).
    for (var i = 0; i < 3; i++) {
      final a = t * 2 * math.pi + i * 2.1;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * r,
          1.2, Paint()..color = AppColors.primary.withAlpha(130));
    }
  }

  @override
  bool shouldRepaint(covariant _ThinkPainter old) => old.t != t;
}

/// ── Slow-analysis loader (kept for network-slow cases): hero + label.
class FalconLoader extends StatelessWidget {
  const FalconLoader({super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const FalconHeroArt(size: 84),
          const SizedBox(height: 10),
          Text(AppLocalizations.of(context).translate('falconThinking'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
        ]),
      );
}
/// Falcon mark with a professional circular halo in DARK theme only:
/// a soft silver/white radial ring (gradient, not a hard stroke) that
/// highlights the logo against deep black + a whisper of burgundy tint.
/// Light theme keeps the plain artwork (its details are visible already).
/// The logo itself is never tinted or recomposed.
class FalconMark extends StatelessWidget {
  final double size;
  final bool halo;
  const FalconMark(this.size, {super.key, this.halo = true});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mark = FalconIcon(size: size);
    if (!dark || !halo) return mark;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        CustomPaint(
          size: Size.square(size * 1.5),
          painter: _DarkHaloPainter(),
        ),
        mark,
      ],
    );
  }
}

class _DarkHaloPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * .5;
    // Soft luminous ring: starts faint, swells near the logo edge, fades
    // out — plus a faint burgundy tint lowlight.
    canvas.drawCircle(
        c, r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0x00F4F6F8),
              Colors.white.withAlpha(40),
              Colors.white.withAlpha(86),
              Colors.white.withAlpha(38),
              AppColors.primary.withAlpha(24),
              const Color(0x00FFFFFF),
            ],
            stops: const [0.0, 0.58, 0.72, 0.82, 0.93, 1.0],
          ).createShader(Rect.fromCircle(center: c, radius: r)));
    // Very soft bloom just outside the logo silhouette.
    canvas.drawCircle(
        c, size.shortestSide * .42,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withAlpha(26),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(
              center: c, radius: size.shortestSide * .42)));
  }

  @override
  bool shouldRepaint(covariant _DarkHaloPainter old) => false;
}
