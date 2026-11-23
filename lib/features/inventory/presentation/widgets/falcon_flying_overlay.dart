import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../../../core/theme/app_colors.dart';
import 'falcon_ambient.dart';

/// ONE OverlayEntry, ONE keyed FalconMark from thinking until dock arrival.
/// Targets are global, recalculated from live RenderBoxes on scroll/layout.
class FalconFlyingOverlay {
  final AnimationController _motion;
  final GlobalKey viewportKey;
  final BuildContext context;
  OverlayEntry? _entry;
  OverlayState? _overlay;
  Rect? _from, _current;
  Rect? Function()? _target;
  bool _visible = true, _disposed = false;
  FalconFlyingOverlay({required TickerProvider vsync, required this.context,
    required this.viewportKey}) : _motion = AnimationController(vsync: vsync);

  Rect? get currentRect => _current;
  bool get attached => _entry != null;

  Rect? _viewport() {
    final box = viewportKey.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size : null;
  }

  void show(Rect? Function() anchor) {
    if (_disposed) return;
    _target = anchor;
    _current = anchor();
    _from = _current;
    _motion.value = 1;
    if (_entry != null) return;
    _overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(builder: (_) => Positioned.fill(
      child: IgnorePointer(child: AnimatedBuilder(animation: _motion,
        builder: (overlayContext, _) {
          final target = _target?.call();
          final overlayBox = _overlay?.context.findRenderObject();
          final view = _viewport();
          final valid = _visible && target != null && view != null &&
              view.overlaps(target) && overlayBox is RenderBox;
          // Keep the exact same element mounted when it leaves the viewport.
          final rect = target == null ? (_current ?? Rect.zero)
              : Rect.lerp(_from ?? target, target,
                  Curves.easeOutCubic.transform(_motion.value))!;
          _current = rect;
          final local = overlayBox is RenderBox
              ? overlayBox.globalToLocal(rect.topLeft) : Offset.zero;
          return Stack(children: [Positioned(left: local.dx, top: local.dy,
            width: rect.width, height: rect.height,
            child: Opacity(opacity: valid ? 1 : 0,
              child: RepaintBoundary(child: Theme(data: Theme.of(context),
                child: DecoratedBox(decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(30), blurRadius: 10)],
                ), child: const SizedBox.expand(
                  child: FittedBox(fit: BoxFit.contain,
                    child: FalconMark(26, key: ValueKey('falcon-reply-cursor'))))),
              )),
            ),
          )]);
        },
      )),
    ));
    _overlay!.insert(_entry!);
  }

  Future<void> moveTo(Rect? Function() target, Duration duration) async {
    if (_disposed) return;
    _from = _current ?? target();
    _target = target;
    _motion.duration = duration;
    try { await _motion.forward(from: 0).orCancel; } on TickerCanceled { /* departed */ }
  }

  /// Scroll is a transform change, not a new flight: the same follower is
  /// attached to the caret's fresh global position, including keyboard inset.
  void trackScroll() {
    if (_disposed) return;
    if (!_motion.isAnimating) _from = _target?.call();
    _entry?.markNeedsBuild();
  }
  void setVisible(bool visible) { _visible = visible; _entry?.markNeedsBuild(); }
  void hide() {
    _motion.stop();
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }
  void dispose() { hide(); _disposed = true; _motion.dispose(); }
}
