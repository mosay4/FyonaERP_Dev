import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Pull-to-refresh with the app's own motion instead of the usual circle:
/// the page glides down a little and a small frosted capsule appears whose
/// three crimson drops fill as you pull, then ripple while refreshing. The
/// page never disappears or reloads in front of the user.
///
/// Drop-in for [RefreshIndicator] (same `onRefresh`/`child`; the material
/// look parameters are accepted and ignored).
class FyonaRefresh extends StatefulWidget {
  const FyonaRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    // Accepted for drop-in compatibility with RefreshIndicator.
    Color? color,
    Color? backgroundColor,
    double? displacement,
    double? edgeOffset,
    double? strokeWidth,
    RefreshIndicatorTriggerMode? triggerMode,
    String? semanticsLabel,
    String? semanticsValue,
  });

  /// Same as `RefreshIndicator.noSpinner` (the motion is still shown).
  const FyonaRefresh.noSpinner({
    super.key,
    required this.onRefresh,
    required this.child,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    RefreshIndicatorTriggerMode? triggerMode,
    double? elevation,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final ScrollNotificationPredicate notificationPredicate;

  @override
  State<FyonaRefresh> createState() => _FyonaRefreshState();
}

class _FyonaRefreshState extends State<FyonaRefresh>
    with TickerProviderStateMixin {
  static const _pullExtent = 110.0;
  static const _restingShift = 46.0;
  static const _minimumShow = Duration(milliseconds: 1100);

  /// 0 → 1 while pulling; held at the resting value while refreshing.
  late final AnimationController _pull = AnimationController(
    vsync: this,
    upperBound: 1.6,
  );
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _refreshing = false;
  bool _armed = false;
  bool _dragging = false;

  /// The list bounces by itself (iOS-style physics): do not move it again.
  bool _bouncing = false;

  /// How far a bouncing list is itself pulled down right now (it springs
  /// back on release; the page is held at the resting offset meanwhile).
  final ValueNotifier<double> _listOver = ValueNotifier(0);

  @override
  void dispose() {
    _pull.dispose();
    _wave.dispose();
    _listOver.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _listOver.value = math.max(0, -n.metrics.pixels);
    }
    if (!widget.notificationPredicate(n) || _refreshing) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    final atTop = n.metrics.extentBefore == 0;
    if (n is ScrollStartNotification) {
      _dragging = n.dragDetails != null;
    } else if (n is OverscrollNotification) {
      // Android (clamping): pulling past the top.
      if (_dragging && atTop && n.overscroll < 0) {
        _bouncing = false;
        _setPull(_pull.value + (-n.overscroll) / _pullExtent * 0.6);
      }
    } else if (n is ScrollUpdateNotification) {
      if (n.dragDetails == null) {
        // The finger left the screen (iOS bounce-back follows): decide now.
        if (_dragging && _pull.value > 0) {
          _dragging = false;
          _release();
        }
      } else if (n.metrics.pixels < 0) {
        // Bouncing physics: the list itself moves; mirror its pull.
        _bouncing = true;
        _setPull(-n.metrics.pixels / _pullExtent);
      } else if (_pull.value > 0 && (n.scrollDelta ?? 0) > 0) {
        // Pushing back up cancels the pull smoothly.
        _setPull(_pull.value - n.scrollDelta! / _pullExtent);
      }
    } else if (n is ScrollEndNotification ||
        (n is UserScrollNotification && n.direction == ScrollDirection.idle)) {
      _dragging = false;
      _release();
    }
    return false;
  }

  void _setPull(double value) {
    final next = value.clamp(0.0, 1.6);
    final armed = next >= 1.0;
    if (armed && !_armed) HapticFeedback.selectionClick();
    _armed = armed;
    _pull.value = next;
  }

  Future<void> _release() async {
    if (_refreshing) return;
    if (!_armed) {
      if (_pull.value > 0) {
        await _pull.animateTo(
          0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    _armed = false;
    setState(() => _refreshing = true);
    unawaited(
      _pull.animateTo(
        1.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
      ),
    );
    _wave.repeat();
    // The motion always plays for a short, pleasant moment, even when the
    // data is already on the device (never a one-frame flash).
    final minimum = Future<void>.delayed(_minimumShow);
    try {
      await widget.onRefresh();
    } catch (_) {
      // The screen reports its own errors; the motion just ends.
    } finally {
      await minimum;
      if (mounted) {
        // Let the current ripple finish before folding away.
        final rest = 1 - _wave.value;
        await Future<void>.delayed(
          Duration(milliseconds: (rest * 900).round().clamp(0, 900)),
        );
        if (!mounted) return;
        _wave.stop();
        await _pull.animateTo(
          0,
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeInOutCubic,
        );
        if (mounted) setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pull, _wave, _listOver]),
        child: widget.child,
        builder: (context, child) {
          final pull = _pull.value;
          final shown = pull.clamp(0.0, 1.0);
          // Rubber-band: the page follows the finger less and less.
          final shift =
              _restingShift *
              (1 - math.exp(-pull * 1.4)) /
              (1 - math.exp(-1.4));
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Transform.translate(
                // Clamping lists: the page follows the pull. Bouncing lists
                // move by themselves while pulling; once refreshing, the page
                // is held at the resting offset as the list springs back, and
                // only returns (gradually) when the dots have folded away.
                offset: Offset(
                  0,
                  !_bouncing
                      ? shift
                      : _refreshing
                      ? math.max(0, shift - _listOver.value)
                      : 0,
                ),
                child: child,
              ),
              if (pull > 0.01)
                Positioned(
                  top: math.max(4, shift / 2 - 16),
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Opacity(
                        opacity: shown,
                        child: Transform.scale(
                          scale: 0.7 + 0.3 * shown,
                          child: _RefreshCapsule(
                            progress: shown,
                            wave: _refreshing ? _wave.value : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}



class _RefreshCapsule extends StatelessWidget {
  const _RefreshCapsule({required this.progress, this.wave});
  final double progress;
  final double? wave;

  @override
  Widget build(BuildContext context) {
    final dark = AppColors.background.computeLuminance() < 0.4;
    final accent = AppColors.primary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: dark
                ? Colors.white.withAlpha(26)
                : Colors.white.withAlpha(215),
            border: Border.all(color: Colors.white.withAlpha(dark ? 50 : 255)),
            boxShadow: [
              BoxShadow(
                color: accent.withAlpha(30),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                _Drop(
                  // While pulling the drops fill one after another; while
                  // refreshing they ripple in turn.
                  fill: wave == null ? ((progress * 3) - i).clamp(0.0, 1.0) : 1,
                  lift: wave == null
                      ? 0
                      : math.max(0, math.sin((wave! - i / 3) * 2 * math.pi)),
                  color: accent,
                ),
                if (i < 2) const SizedBox(width: 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Drop extends StatelessWidget {
  const _Drop({required this.fill, required this.lift, required this.color});
  final double fill;
  final double lift;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final size = 7.0 + 3 * fill + 2 * lift;
    return Transform.translate(
      offset: Offset(0, -4 * lift),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.lerp(color.withAlpha(45), color, fill),
          boxShadow: lift > 0.1
              ? [BoxShadow(color: color.withAlpha(70), blurRadius: 6)]
              : null,
        ),
      ),
    );
  }
}
