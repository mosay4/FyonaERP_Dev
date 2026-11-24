import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// One tab of [LiquidGlassNavBar].
class LiquidGlassNavItem {
  const LiquidGlassNavItem({
    required this.label,
    required this.icon,
    this.badge = false,
  });

  final String label;

  /// Builds the glyph for the given state/colour (lets each section keep its
  /// own icon set: Material icons or the two-tone app icons).
  final Widget Function(bool active, Color color) icon;
  final bool badge;
}

/// The bottom bar in «liquid glass» style, shared by the Personal and the
/// Business sections (same buttons and order as before).
///
/// Layers, back to front:
///  1. a soft backdrop in the theme's own tone;
///  2. coloured lights that drift slowly behind the glass (one follows the
///     active tab) — the glass blurs them so they glow through;
///  3. the frosted glass capsule: tinted body, gradient rim, top sheen;
///  4. a glass lens over the active tab that flows to the next tab — it
///     stretches and squashes like liquid while travelling and settles with a
///     soft spring.
/// Pure Flutter (blur + gradients): identical on every Android phone and on
/// iPhone, no experimental graphics engine.
class LiquidGlassNavBar extends StatefulWidget {
  const LiquidGlassNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.accent,
  });

  final List<LiquidGlassNavItem> items;

  /// -1 when no tab is current (a page outside the tabs).
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Color? accent;

  @override
  State<LiquidGlassNavBar> createState() => _LiquidGlassNavBarState();
}

class _LiquidGlassNavBarState extends State<LiquidGlassNavBar>
    with TickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 640),
  );

  /// The background lights drift through one full, seamless cycle when the
  /// bar appears and on every tab change, then rest (no endless redraw, no
  /// battery cost while the user reads a screen).
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late double _from = widget.currentIndex.toDouble();
  late double _to = widget.currentIndex.toDouble();

  @override
  void initState() {
    super.initState();
    _drift.forward();
  }

  @override
  void didUpdateWidget(covariant LiquidGlassNavBar old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      final now = _position;
      _from = now.isFinite ? now : widget.currentIndex.toDouble();
      _to = widget.currentIndex.toDouble();
      if (_from < 0 || _to < 0) {
        _from = _to;
        _flow.value = 1;
      } else {
        _flow.forward(from: 0);
        _drift.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    _drift.dispose();
    super.dispose();
  }

  /// Position along the tabs (spring-like settle).
  double get _position {
    final t = _spring(_flow.value.clamp(0.0, 1.0));
    return _from + (_to - _from) * t;
  }

  /// Critically damped spring with one soft overshoot.
  static double _spring(double t) =>
      1 - math.exp(-6.5 * t) * math.cos(t * math.pi * 1.35);

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.background.computeLuminance() < 0.4;
    final accent = widget.accent ?? AppColors.primary;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final n = widget.items.length;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion && _drift.isAnimating) _drift.value = 1;

    // The bar's own backdrop: the page tone, fading in from transparent so
    // there is no hard edge above the bar.
    final base = AppColors.background;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            base.withAlpha(0),
            base,
            dark
                ? Color.alphaBlend(accent.withAlpha(18), base)
                : Color.alphaBlend(accent.withAlpha(8), base),
          ],
          stops: const [0, 0.35, 1],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, 10, 16, math.max(bottomPad, 10) + 2),
      child: SizedBox(
        height: 68,
        child: LayoutBuilder(
          builder: (context, box) {
            final slot = box.maxWidth / math.max(n, 1);
            double centreOf(double p) =>
                rtl ? box.maxWidth - (p + 0.5) * slot : (p + 0.5) * slot;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // Outer glow of the whole capsule.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(34),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withAlpha(dark ? 40 : 22),
                          blurRadius: 36,
                          spreadRadius: -10,
                          offset: const Offset(0, 10),
                        ),
                        BoxShadow(
                          color: Colors.black.withAlpha(dark ? 90 : 14),
                          blurRadius: 24,
                          spreadRadius: -12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(34),
                  child: Stack(
                    children: [
                      // 2. Lights behind the glass.
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_drift, _flow]),
                            builder: (context, _) => CustomPaint(
                              painter: _LightsPainter(
                                phase: Curves.easeInOut.transform(_drift.value),
                                focus: widget.currentIndex < 0
                                    ? null
                                    : centreOf(_position) / box.maxWidth,
                                accent: accent,
                                dark: dark,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 3. Frosted glass.
                      Positioned.fill(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: dark
                                    ? [
                                        Colors.white.withAlpha(22),
                                        Colors.white.withAlpha(6),
                                      ]
                                    : [
                                        Colors.white.withAlpha(150),
                                        Colors.white.withAlpha(92),
                                      ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Top sheen: light falling on the glass.
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: 30,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withAlpha(dark ? 26 : 120),
                                  Colors.white.withAlpha(0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Gradient rim (bright on top, fading at the bottom).
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _RimPainter(dark: dark, accent: accent),
                    ),
                  ),
                ),
                // 4. The glass lens over the active tab.
                if (widget.currentIndex >= 0)
                  AnimatedBuilder(
                    animation: _flow,
                    builder: (context, _) {
                      final p = _position;
                      final t = _flow.value.clamp(0.0, 1.0);
                      final travel = math.sin(math.pi * t);
                      final distance = (_to - _from).abs().clamp(0, 2.5);
                      final stretch = 1 + 0.42 * travel * distance;
                      final squash = 1 - 0.14 * travel * math.min(distance, 1);
                      final width = math.min(slot - 8, 70.0) * stretch;
                      final height = 56.0 * squash;
                      return Positioned(
                        left: centreOf(p) - width / 2,
                        top: (68 - height) / 2,
                        width: width,
                        height: height,
                        child: _GlassLens(accent: accent, dark: dark),
                      );
                    },
                  ),
                Positioned.fill(
                  child: Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        Expanded(
                          child: _Tab(
                            item: widget.items[i],
                            active: i == widget.currentIndex,
                            accent: dark
                                ? Color.lerp(accent, Colors.white, 0.38)!
                                : accent,
                            idle: dark
                                ? Colors.white.withAlpha(165)
                                : const Color(0xFF5A6070),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              widget.onTap(i);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Coloured lights drifting behind the glass. [focus] (0–1 across the bar)
/// places a warm light under the active tab.
class _LightsPainter extends CustomPainter {
  _LightsPainter({
    required this.phase,
    required this.focus,
    required this.accent,
    required this.dark,
  });

  final double phase;
  final double? focus;
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    // Base tint of the glass interior.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = dark ? const Color(0xFF120F14) : const Color(0xFFF6F4F6),
    );
    final w = size.width, h = size.height;
    final a = phase * 2 * math.pi;
    void light(Offset c, double r, Color color) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withAlpha(0)],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    final rose = dark ? const Color(0xFFE0405E) : const Color(0xFFF07A92);
    final gold = dark ? const Color(0xFFB8862F) : const Color(0xFFF3C27A);
    final violet = dark ? const Color(0xFF5B4BB7) : const Color(0xFFB7A8F0);
    light(
      Offset(w * (0.18 + 0.08 * math.sin(a)), h * (0.6 + 0.2 * math.cos(a))),
      h * 1.6,
      rose.withAlpha(dark ? 80 : 85),
    );
    light(
      Offset(w * (0.55 + 0.1 * math.cos(a * 1.3)), h * (0.9 + 0.15 * math.sin(a))),
      h * 1.4,
      gold.withAlpha(dark ? 26 : 70),
    );
    light(
      Offset(w * (0.88 - 0.07 * math.sin(a * 0.8)), h * (0.3 + 0.2 * math.sin(a))),
      h * 1.5,
      violet.withAlpha(dark ? 85 : 60),
    );
    if (focus != null) {
      light(
        Offset(w * focus!, h * 0.55),
        h * 1.1,
        accent.withAlpha(dark ? 80 : 55),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LightsPainter old) =>
      old.phase != phase ||
      old.focus != focus ||
      old.dark != dark ||
      old.accent != accent;
}

class _RimPainter extends CustomPainter {
  _RimPainter({required this.dark, required this.accent});
  final bool dark;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.6);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(34));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [
                  Colors.white.withAlpha(70),
                  Colors.white.withAlpha(14),
                  accent.withAlpha(40),
                ]
              : [
                  Colors.white,
                  Colors.white.withAlpha(150),
                  accent.withAlpha(36),
                ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _RimPainter old) =>
      old.dark != dark || old.accent != accent;
}

/// The glass lens marking the active tab.
class _GlassLens extends StatelessWidget {
  const _GlassLens({required this.accent, required this.dark});
  final Color accent;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? [Colors.white.withAlpha(34), Colors.white.withAlpha(10)]
                : [Colors.white.withAlpha(235), Colors.white.withAlpha(150)],
          ),
          border: Border.all(
            color: Colors.white.withAlpha(dark ? 70 : 255),
            width: 1.1,
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withAlpha(dark ? 70 : 40),
              blurRadius: 16,
              spreadRadius: -6,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Stack(
          children: [
            // Curved specular highlight across the top of the lens.
            Positioned(
              left: 14,
              right: 14,
              top: 4,
              height: 11,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                    bottom: Radius.circular(40),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withAlpha(dark ? 40 : 160),
                      Colors.white.withAlpha(0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.item,
    required this.active,
    required this.accent,
    required this.idle,
    required this.onTap,
  });

  final LiquidGlassNavItem item;
  final bool active;
  final Color accent;
  final Color idle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? accent : idle;
    return Semantics(
      selected: active,
      button: true,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(end: active ? 1 : 0),
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutBack,
                  builder: (context, v, child) => Transform.translate(
                    offset: Offset(0, -1.5 * v),
                    child: Transform.scale(scale: 1 + 0.1 * v, child: child),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: Center(child: item.icon(active, color)),
                      ),
                      if (item.badge)
                        Positioned(
                          top: -1,
                          right: -1,
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: AppColors.danger,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1.3,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 280),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    height: 1.2,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    color: color,
                  ),
                  child: Text(item.label, maxLines: 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
