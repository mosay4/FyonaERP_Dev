import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Elegant three-dot loading indicator (brand alternative to the spinning circle).
///
/// The dots pulse in a gradual wave: each one grows then shrinks in sequence,
/// with fading opacity — a professional reload mark in contrasting colors.
class DotsLoader extends StatefulWidget {
  /// Base dot diameter.
  final double size;

  /// Space between dots.
  final double spacing;

  /// One color per dot. Defaults to an elegant brand trio.
  final List<Color>? colors;

  /// Single color for all dots (e.g. white inside colored buttons).
  final Color? color;

  const DotsLoader({
    super.key,
    this.size = 12,
    this.spacing = 8,
    this.colors,
    this.color,
  });

  /// Small white version for loading states inside colored buttons.
  const DotsLoader.button({
    super.key,
    this.size = 8,
    this.spacing = 6,
  })  : colors = null,
        color = Colors.white;

  static const _defaultColors = [
    AppColors.primaryLight,
    AppColors.primary,
    AppColors.gold,
  ];

  @override
  State<DotsLoader> createState() => _DotsLoaderState();
}

class _DotsLoaderState extends State<DotsLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.color != null
        ? [widget.color!, widget.color!, widget.color!]
        : (widget.colors ?? DotsLoader._defaultColors);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        // Staggered wave: dot i animates on [i*0.2, 0.6 + i*0.2].
        final start = i * 0.2;
        final end = 0.6 + i * 0.2;
        return AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            final t = ((_ctrl.value - start) / (end - start)).clamp(0.0, 1.0);
            // Smooth grow-then-shrink curve over the dot's window.
            final wave = (t < 0.5 ? t * 2 : (1 - t) * 2).clamp(0.0, 1.0);
            final eased = Curves.easeInOut.transform(wave);
            final scale = 0.45 + 0.55 * eased;
            final opacity = 0.35 + 0.65 * eased;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.spacing / 2),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: widget.size * scale,
                  height: widget.size * scale,
                  decoration: BoxDecoration(
                    color: palette[i % palette.length],
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: palette[i % palette.length].withAlpha(90),
                        blurRadius: 8 * eased,
                        spreadRadius: 1 * eased,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }
}
