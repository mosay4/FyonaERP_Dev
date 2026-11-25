import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../router/app_router.dart';
import '../../shared/providers/locale_provider.dart';
import 'catalog/help_catalog.dart';
import 'catalog/help_registry.dart';
import 'help_clicker_settings.dart';
import 'help_detector.dart';

export 'help_target.dart' show HelpTarget;

const _kRed = Color(0xFFE63946);
const _kRedDeep = Color(0xFFA01530);
const _kCard = Color(0xFF0C0C0E);

/// Hit-test tag marking a subtree as off-limits for the Information Clicker.
///
/// Wrap transaction rows, chat bubbles or any record whose long-press already
/// belongs to a native action (copy, receipt, delete…) in [ClickerQuiet]:
/// the overlay then stays completely silent there — no progress border, no
/// explanation card — while the widget's own gestures keep working untouched.
class ClickerQuiet extends StatelessWidget {
  final Widget child;
  const ClickerQuiet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: kClickerQuietTag,
      // Opaque (not deferToChild) so this box always joins the hit-test
      // path and the overlay can see the marker. It owns no gesture
      // recognizer, so taps, drags and scrolls pass through unchanged.
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }
}

/// Arena member that wins only after the full hold duration.
///
/// * Quick taps: it rejects itself on pointer-up, so the button's own tap
///   fires normally.
/// * Drags/scrolls: it gives up as soon as the finger travels past the touch
///   slop.
/// * Native long presses: the press is probed first and stays quiet there,
///   so the element's own long press is never contested.
/// * Tooltips: a tooltip's long press wins the arena after ~0.5s but only
///   shows a bubble; [survivesRejection] lets the hold keep counting so
///   icon buttons with a tooltip still get their help.
class _ClickerRecognizer extends OneSequenceGestureRecognizer {
  _ClickerRecognizer();

  Duration Function()? getDuration;
  void Function(Offset position)? onTrigger;
  void Function(Offset position)? onPressStart;
  VoidCallback? onPressEnd;
  bool Function()? survivesRejection;

  Timer? _timer;
  Offset? _downPosition;
  int? _pointer;
  bool _resolved = false;

  @override
  String get debugDescription => 'clicker';

  @override
  void didStopTrackingLastPointer(int pointer) {}

  void _settle(GestureDisposition d) {
    if (_resolved) return;
    _resolved = true;
    resolve(d);
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    final p = _pointer;
    _pointer = null;
    _downPosition = null;
    if (p != null) stopTrackingPointer(p);
    try {
      onPressEnd?.call();
    } catch (_) {}
  }

  void _cancel() {
    _settle(GestureDisposition.rejected);
    _finish();
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _resolved = false;
    _downPosition = event.position;
    super.addAllowedPointer(event);
    try {
      onPressStart?.call(event.position);
    } catch (_) {}
    _timer?.cancel();
    final duration = getDuration?.call() ?? const Duration(seconds: 2);
    _timer = Timer(duration, () {
      _timer = null;
      final pos = _downPosition;
      if (_pointer == null || pos == null) return;
      // Winning here rejects the element's tap: releasing after the card
      // opens never also presses the button.
      _settle(GestureDisposition.accepted);
      _finish();
      onTrigger?.call(pos);
    });
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      final down = _downPosition;
      if (down != null && (event.position - down).distance > kTouchSlop) {
        _cancel();
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _cancel();
    }
  }

  @override
  void rejectGesture(int pointer) {
    _resolved = true;
    if (_timer != null && (survivesRejection?.call() ?? false)) {
      // Keep tracking moves/ups through the pointer route.
      return;
    }
    _finish();
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// A press the clicker can explain: where it is and what to say.
class _Decision {
  final HelpProbe probe;
  final HelpMatch match;
  const _Decision(this.probe, this.match);
}

class InformationClickerOverlay extends ConsumerStatefulWidget {
  final Widget child;

  /// Catalog override (tests). Defaults to the app catalog.
  final HelpCatalog? catalog;

  /// Route override (tests). Defaults to the router's current location.
  final String Function()? routeOf;

  /// Language override (tests). Defaults to the app locale.
  final bool Function()? arabicOf;

  const InformationClickerOverlay({
    super.key,
    required this.child,
    this.catalog,
    this.routeOf,
    this.arabicOf,
  });

  @override
  ConsumerState<InformationClickerOverlay> createState() =>
      _InformationClickerOverlayState();
}

class _InformationClickerOverlayState
    extends ConsumerState<InformationClickerOverlay> {
  final GlobalKey<OverlayState> _overlayKey = GlobalKey<OverlayState>();
  OverlayEntry? _entry;
  OverlayEntry? _progressEntry;
  Timer? _progressDelay;
  _Decision? _pending;

  /// How long the finger may rest on the screen before the progress border
  /// starts drawing. A normal tap releases well before this, so quick taps
  /// never flash a border around whatever they touched.
  static const Duration _pressGrace = Duration(milliseconds: 350);

  HelpCatalog get _catalog => widget.catalog ?? HelpRegistry.catalog;

  @override
  void dispose() {
    _progressDelay?.cancel();
    _progressDelay = null;
    _hideProgress();
    _removeEntry();
    super.dispose();
  }

  String _currentRoute() {
    final custom = widget.routeOf;
    if (custom != null) return custom();
    try {
      return ref.read(goRouterProvider).state.uri.toString();
    } catch (_) {
      return '';
    }
  }

  bool _isArabic() {
    final custom = widget.arabicOf;
    if (custom != null) return custom();
    try {
      return ref.read(localeProvider).languageCode != 'en';
    } catch (_) {
      try {
        return Localizations.localeOf(context).languageCode != 'en';
      } catch (_) {
        return true;
      }
    }
  }

  /// Finds the element under [anchor] and its curated help. Null means the
  /// press must stay completely quiet (background, user data, text fields,
  /// elements with their own long press, or no curated help).
  _Decision? _decide(Offset anchor) {
    if (!mounted) return null;
    final view = View.of(context);
    final size = MediaQuery.sizeOf(context);
    final found =
        HelpDetector.probeAt(anchor, viewId: view.viewId, screen: size);
    final probe = found.probe;
    if (probe == null) return null;
    final match = _catalog.resolve(probe,
        route: _currentRoute(), arabic: _isArabic());
    if (match == null) return null;
    return _Decision(probe, match);
  }

  void _showProgress(Offset anchor) {
    _pending = null;
    if (!mounted || _entry != null || _progressEntry != null) return;
    if (_progressDelay != null) return;
    final settings = ref.read(helpClickerProvider);
    if (!settings.enabled) return;
    final decision = _decide(anchor);
    if (decision == null) return;
    _pending = decision;
    final total = settings.seconds * 1000;
    // Elapsed-time progress: the controller runs on the FULL press duration
    // and starts at the fraction already spent inside the grace window, so
    // the border completes at exactly the same instant the trigger fires.
    final startAt = (_pressGrace.inMilliseconds / total).clamp(0.0, 1.0);
    _progressDelay = Timer(_pressGrace, () {
      _progressDelay = null;
      if (!mounted || _entry != null || _progressEntry != null) return;
      if (!identical(_pending, decision)) return;
      final entry = OverlayEntry(
        builder: (_) => Positioned.fill(
          child: IgnorePointer(
            child: _ProgressBorder(
              target: decision.probe.liveRect,
              duration: Duration(milliseconds: total),
              startAt: startAt,
            ),
          ),
        ),
      );
      _progressEntry = entry;
      _overlayKey.currentState?.insert(entry);
    });
  }

  void _hideProgress() {
    _progressDelay?.cancel();
    _progressDelay = null;
    final e = _progressEntry;
    _progressEntry = null;
    try {
      e?.remove();
    } catch (_) {}
  }

  void _showAt(Offset anchor) {
    if (_entry != null || !mounted) return;
    final settings = ref.read(helpClickerProvider);
    final pending = _pending;
    _pending = null;
    _hideProgress();
    if (!settings.enabled || pending == null) return;
    // Re-probe at trigger time: the screen may have changed during the hold.
    final decision = _decide(anchor);
    if (decision == null ||
        decision.match.entry.id != pending.match.entry.id) {
      return;
    }
    try {
      Tooltip.dismissAllToolTips();
    } catch (_) {}
    final arabic = _isArabic();
    final route = _currentRoute().toLowerCase();
    final sara = route.startsWith('/personal/ai') ||
        route.startsWith('/ai') && !route.startsWith('/ai-suggestions');
    final media = MediaQuery.of(context);
    _removeEntry();
    final entry = OverlayEntry(
      builder: (_) => _SpotlightHost(
        anchor: anchor,
        target: decision.probe.liveRect(),
        match: decision.match,
        avatar: sara ? 'assets/images/sara_avatar.jpg' : null,
        arabic: arabic,
        screenSize: media.size,
        padding: media.padding,
        onClose: _removeEntry,
      ),
    );
    _entry = entry;
    _overlayKey.currentState?.insert(entry);
  }

  void _removeEntry() {
    final e = _entry;
    _entry = null;
    try {
      e?.remove();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Watch settings so the persisted duration is loaded long before the
    // first press and the overlay follows on/off changes.
    ref.watch(helpClickerProvider);
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            excludeFromSemantics: true,
            gestures: <Type, GestureRecognizerFactory>{
              _ClickerRecognizer:
                  GestureRecognizerFactoryWithHandlers<_ClickerRecognizer>(
                () => _ClickerRecognizer(),
                (_ClickerRecognizer instance) {
                  instance.getDuration = () => Duration(
                      milliseconds:
                          ref.read(helpClickerProvider).seconds * 1000);
                  instance.onTrigger = (pos) {
                    if (mounted) _showAt(pos);
                  };
                  instance.onPressStart = (pos) {
                    if (mounted) _showProgress(pos);
                  };
                  instance.onPressEnd = () {
                    if (mounted) _hideProgress();
                  };
                  instance.survivesRejection =
                      () => _pending?.probe.hasTooltip ?? false;
                },
              ),
            },
            child: const SizedBox.expand(),
          ),
        ),
        Overlay(key: _overlayKey),
      ],
    );
  }
}

class _SpotlightHost extends StatefulWidget {
  final Offset anchor;
  final Rect target;
  final HelpMatch match;
  final String? avatar;
  final bool arabic;
  final Size screenSize;
  final EdgeInsets padding;
  final VoidCallback onClose;

  const _SpotlightHost({
    required this.anchor,
    required this.target,
    required this.match,
    required this.avatar,
    required this.arabic,
    required this.screenSize,
    required this.padding,
    required this.onClose,
  });

  @override
  State<_SpotlightHost> createState() => _SpotlightHostState();
}

class _SpotlightHostState extends State<_SpotlightHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<double> _pop = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    _controller.reverse().whenComplete(widget.onClose);
  }

  @override
  Widget build(BuildContext context) {
    final screenW = widget.screenSize.width;
    final screenH = widget.screenSize.height;
    final topLimit = widget.padding.top + 8;
    final bottomLimit = screenH - widget.padding.bottom - 8;
    final target = widget.target;
    final targetCenterX = target.center.dx.clamp(0.0, screenW);
    final targetTop = target.top;
    final targetBottom = target.bottom;

    final hole = target.inflate(6);
    final cardWidth = (screenW - 32).clamp(200.0, 360.0);
    final cardLeft = (targetCenterX - cardWidth / 2)
        .clamp(16.0, (screenW - cardWidth - 16).clamp(16.0, screenW));
    final spaceAbove = targetTop - topLimit - 18;
    final spaceBelow = bottomLimit - targetBottom - 18;
    final showAbove = spaceAbove >= 250 || spaceAbove >= spaceBelow;
    final available = (showAbove ? spaceAbove : spaceBelow).clamp(170.0, 430.0);

    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        final dim = (_controller.value * 178).round().clamp(0, 178);
        final t = _pop.value;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: CustomPaint(
                  painter: _DimPainter(hole: hole, dimAlpha: dim),
                  size: Size.infinite,
                ),
              ),
            ),
            Positioned(
              left: cardLeft,
              width: cardWidth,
              top: showAbove ? null : targetBottom + 16,
              bottom: showAbove ? screenH - targetTop + 16 : null,
              child: Opacity(
                opacity: _controller.value.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: (0.86 + 0.14 * t).clamp(0.6, 1.05),
                  alignment: showAbove
                      ? Alignment.bottomCenter
                      : Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: available),
                    child: _SpotCard(
                      match: widget.match,
                      avatar: widget.avatar,
                      arabic: widget.arabic,
                      tailDown: showAbove,
                      tailX: (targetCenterX - cardLeft)
                          .clamp(36.0, cardWidth - 36.0),
                      onClose: _close,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DimPainter extends CustomPainter {
  final Rect? hole;
  final int dimAlpha;

  _DimPainter({required this.hole, required this.dimAlpha});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRect(Offset.zero & size);
    final h = hole;
    final radius = Radius.circular(_ringRadius(h));
    if (h != null && !h.isEmpty) {
      path.addRRect(RRect.fromRectAndRadius(h, radius));
      path.fillType = PathFillType.evenOdd;
    }
    canvas.drawPath(path, Paint()..color = Colors.black.withAlpha(dimAlpha));
    if (h != null && !h.isEmpty) {
      final frame = RRect.fromRectAndRadius(h, radius);
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = _kRed.withAlpha(80)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      canvas.drawRRect(frame, glow);
      final edge = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = _kRed;
      canvas.drawRRect(frame, edge);
    }
  }

  @override
  bool shouldRepaint(covariant _DimPainter old) =>
      old.hole != hole || old.dimAlpha != dimAlpha;
}

/// Ring corner radius that hugs the element: round for small icon buttons,
/// softer for wide rows.
double _ringRadius(Rect? r) {
  if (r == null) return 16;
  return math.min(22.0, r.shortestSide / 2);
}

class _SpotCard extends StatelessWidget {
  final HelpMatch match;
  final String? avatar;
  final bool arabic;
  final bool tailDown;
  final double tailX;
  final VoidCallback onClose;

  const _SpotCard({
    required this.match,
    required this.avatar,
    required this.arabic,
    required this.tailDown,
    required this.tailX,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final align = arabic ? TextAlign.right : TextAlign.left;
    final dir = arabic ? TextDirection.rtl : TextDirection.ltr;
    return Directionality(
      textDirection: dir,
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'Cairo',
          decoration: TextDecoration.none,
          color: Color(0xFFE8E8E8),
          fontSize: 13,
        ),
        child: CustomPaint(
          painter: _SpotCardPainter(tailDown: tailDown, tailX: tailX),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              top: tailDown ? 14 : 28,
              bottom: tailDown ? 30 : 14,
              left: 16,
              right: 16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HelpIconBadge(
                        key: ValueKey(match.entry.id),
                        icon: match.entry.icon,
                        avatar: avatar),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            match.title,
                            textAlign: align,
                            softWrap: true,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              decoration: TextDecoration.none,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            match.body,
                            textAlign: align,
                            softWrap: true,
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              decoration: TextDecoration.none,
                              fontSize: 13,
                              height: 1.6,
                              color: Color(0xFFD9D9D9),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: onClose,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withAlpha(14),
                          border:
                              Border.all(color: Colors.white.withAlpha(60)),
                        ),
                        child: const Icon(Icons.close_rounded,
                            size: 15, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                // Elements without a real flow show the idea only — never a
                // filler "how to use" block.
                if (match.how.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 5),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFE0393E), _kRedDeep],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        arabic ? 'طريقة الاستخدام' : 'How to use',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          decoration: TextDecoration.none,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < match.how.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: _kRed,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                decoration: TextDecoration.none,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              match.how[i],
                              textAlign: align,
                              softWrap: true,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                decoration: TextDecoration.none,
                                fontSize: 12.5,
                                height: 1.6,
                                color: Color(0xFFE8E8E8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The element's icon, introduced with one elegant, FINITE motion: it pops
/// in with a soft spring and a quarter-turn settle while a single glow ring
/// ripples out of the badge. Nothing loops, so the card is static once the
/// entrance ends (and `pumpAndSettle` settles).
class _HelpIconBadge extends StatefulWidget {
  final IconData icon;
  final String? avatar;
  const _HelpIconBadge({super.key, required this.icon, this.avatar});

  @override
  State<_HelpIconBadge> createState() => _HelpIconBadgeState();
}

class _HelpIconBadgeState extends State<_HelpIconBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();

  late final Animation<double> _pop = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.0, 0.65, curve: Curves.elasticOut),
  );
  late final Animation<double> _turn = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _ripple = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.25, 1.0, curve: Curves.easeOut),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    final face = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFF3A0B10), Color(0xFF120304)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border.all(color: _kRed.withAlpha(110)),
        boxShadow: [
          BoxShadow(color: _kRed.withAlpha(70), blurRadius: 18, spreadRadius: 1),
        ],
      ),
      alignment: Alignment.center,
      child: widget.avatar != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(widget.avatar!,
                  width: 40, height: 40, fit: BoxFit.cover),
            )
          : Icon(widget.icon, size: 28, color: Colors.white),
    );
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) {
          final r = _ripple.value;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (r > 0 && r < 1)
                IgnorePointer(
                  child: Container(
                    width: size + 22 * r,
                    height: size + 22 * r,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16 + 8 * r),
                      border: Border.all(
                        color: _kRed.withAlpha((150 * (1 - r)).round()),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              Transform.rotate(
                angle: (1 - _turn.value) * -math.pi / 6,
                child: Transform.scale(
                  scale: 0.4 + 0.6 * _pop.value,
                  child: child,
                ),
              ),
            ],
          );
        },
        child: face,
      ),
    );
  }
}

class _SpotCardPainter extends CustomPainter {
  final bool tailDown;
  final double tailX;

  _SpotCardPainter({required this.tailDown, required this.tailX});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const radius = 26.0;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(2, tailDown ? 2 : 16, w - 4, h - 18 - 2),
      const Radius.circular(radius),
    );
    final path = Path()..addRRect(body);
    final tipX = tailX.clamp(40.0, w - 40.0);
    final tail = Path();
    if (tailDown) {
      final baseY = body.bottom - 2;
      tail.moveTo(tipX - 15, baseY);
      tail.quadraticBezierTo(tipX - 5, baseY + 14, tipX, h - 1);
      tail.quadraticBezierTo(tipX + 5, baseY + 14, tipX + 15, baseY);
    } else {
      final baseY = body.top + 2;
      tail.moveTo(tipX - 15, baseY);
      tail.quadraticBezierTo(tipX - 5, baseY - 14, tipX, 1);
      tail.quadraticBezierTo(tipX + 5, baseY - 14, tipX + 15, baseY);
    }
    tail.close();
    path.addPath(tail, Offset.zero);

    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = _kCard;
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = _kRed.withAlpha(90)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = _kRed;
    canvas.drawPath(path, fill);
    canvas.drawPath(path, glow);
    canvas.drawPath(path, edge);
  }

  @override
  bool shouldRepaint(covariant _SpotCardPainter old) =>
      old.tailDown != tailDown || old.tailX != tailX;
}

class _ProgressBorder extends StatefulWidget {
  /// Live bounds of the pressed element (follows it if it scrolls).
  final Rect Function() target;

  /// Full press duration from Touch Down (same value the trigger timer
  /// uses).
  final Duration duration;

  /// Progress already elapsed when the border first paints (the grace
  /// window), so the ring lands at 100% exactly on trigger.
  final double startAt;
  const _ProgressBorder({
    required this.target,
    required this.duration,
    this.startAt = 0,
  });

  @override
  State<_ProgressBorder> createState() => _ProgressBorderState();
}

class _ProgressBorderState extends State<_ProgressBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward(from: widget.startAt.clamp(0.0, 1.0));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) => CustomPaint(
        painter: _ProgressBorderPainter(
          rect: widget.target(),
          progress: _controller.value,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _ProgressBorderPainter extends CustomPainter {
  final Rect rect;
  final double progress;

  _ProgressBorderPainter({required this.rect, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final hole = rect.inflate(4);
    final frame =
        RRect.fromRectAndRadius(hole, Radius.circular(_ringRadius(hole)));
    canvas.drawRRect(frame, Paint()..color = _kRed.withAlpha(24));
    final faint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withAlpha(34);
    canvas.drawRRect(frame, faint);
    final path = Path()..addRRect(frame);
    for (final metric in path.computeMetrics()) {
      final total = metric.length;
      if (total <= 0) continue;
      final drawn = metric.extractPath(0, total * progress.clamp(0.0, 1.0));
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = _kRed.withAlpha(85)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawPath(drawn, glow);
      final edge = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..color = _kRed;
      canvas.drawPath(drawn, edge);
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressBorderPainter old) =>
      old.progress != progress || old.rect != rect;
}
