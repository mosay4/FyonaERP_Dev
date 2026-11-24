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
/// A floating frosted capsule with a light rim and a glass drop that flows
/// from tab to tab: it stretches while it travels and settles with a soft
/// spring. Pure Flutter (blur + gradients), so it renders the same on every
/// Android phone and on iPhone, with no special graphics engine needed.
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late double _from = widget.currentIndex.toDouble();
  late double _to = widget.currentIndex.toDouble();

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
      }
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  double get _position {
    final t = Curves.easeOutBack.transform(_flow.value.clamp(0.0, 1.0));
    return _from + (_to - _from) * t;
  }

  @override
  Widget build(BuildContext context) {
    // The app's own palette decides (it follows the app's light/dark mode).
    final dark = AppColors.background.computeLuminance() < 0.4;
    final accent = widget.accent ?? AppColors.primary;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final n = widget.items.length;
    return Container(
      color: AppColors.background,
      padding: EdgeInsets.fromLTRB(14, 6, 14, math.max(bottomPad, 8) + 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 66,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              // Frosted body: brighter at the top like light on glass.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? [Colors.white.withAlpha(30), Colors.white.withAlpha(12)]
                    : [
                        Colors.white.withAlpha(235),
                        Colors.white.withAlpha(190),
                      ],
              ),
              border: Border.all(
                color: dark
                    ? Colors.white.withAlpha(40)
                    : Colors.white.withAlpha(255),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withAlpha(dark ? 40 : 28),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: Colors.black.withAlpha(dark ? 60 : 14),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                final slot = box.maxWidth / math.max(n, 1);
                return Stack(
                  children: [
                    // Specular rim along the top edge.
                    Positioned(
                      left: 18,
                      right: 18,
                      top: 1,
                      height: 1.4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withAlpha(0),
                              Colors.white.withAlpha(dark ? 90 : 255),
                              Colors.white.withAlpha(0),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // The glass drop flowing between tabs.
                    if (widget.currentIndex >= 0)
                      AnimatedBuilder(
                        animation: _flow,
                        builder: (context, _) {
                          final p = _position;
                          // Stretch while travelling, round when resting.
                          final travel = math.sin(
                            math.pi * _flow.value.clamp(0.0, 1.0),
                          );
                          final distance = (_to - _from).abs().clamp(0, 2);
                          final width =
                              math.min(slot - 10, 64.0) *
                              (1 + 0.45 * travel * distance);
                          final centre = rtl
                              ? box.maxWidth - (p + 0.5) * slot
                              : (p + 0.5) * slot;
                          return Positioned(
                            left: centre - width / 2,
                            top: 6,
                            width: width,
                            height: 54,
                            child: _GlassDrop(accent: accent, dark: dark),
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
                                accent: accent,
                                idle: dark
                                    ? Colors.white.withAlpha(170)
                                    : const Color(0xFF5B6270),
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
        ),
      ),
    );
  }
}

class _GlassDrop extends StatelessWidget {
  const _GlassDrop({required this.accent, required this.dark});
  final Color accent;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withAlpha(dark ? 70 : 40),
            accent.withAlpha(dark ? 40 : 18),
          ],
        ),
        border: Border.all(color: Colors.white.withAlpha(dark ? 60 : 200)),
        boxShadow: [
          BoxShadow(
            color: accent.withAlpha(45),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Align(
        alignment: const Alignment(-0.4, -0.85),
        child: FractionallySizedBox(
          widthFactor: 0.5,
          heightFactor: 0.18,
          // Inner highlight: the «wet» shine of a drop.
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withAlpha(dark ? 40 : 150),
            ),
          ),
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
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedScale(
                scale: active ? 1.1 : 1.0,
                duration: const Duration(milliseconds: 360),
                curve: Curves.easeOutBack,
                child: AnimatedSlide(
                  offset: Offset.zero,
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
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
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 260),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  color: color,
                ),
                child: Text(item.label, maxLines: 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
