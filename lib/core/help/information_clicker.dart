import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../router/app_router.dart';
import '../../shared/providers/locale_provider.dart';
import 'help_clicker_settings.dart';
import 'help_allowlist.dart';
import 'help_content.dart';
import 'help_explain.dart';

const _kRed = Color(0xFFE63946);
const _kRedDeep = Color(0xFFA01530);
const _kCard = Color(0xFF0C0C0E);

/// Hit-test tag marking a subtree as off-limits for the Information Clicker.
///
/// Wrap transaction rows, chat bubbles or any record whose long-press already
/// belongs to a native action (copy, receipt, delete…) in [ClickerQuiet]:
/// the overlay then stays completely silent there — no progress border, no
/// explanation card — while the widget's own gestures keep working untouched.
const _kClickerQuietTag = 'fyona.clicker.quiet.v1';

class ClickerQuiet extends StatelessWidget {
  final Widget child;
  const ClickerQuiet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: _kClickerQuietTag,
      // Opaque (not deferToChild) so this box always joins the hit-test
      // path and the overlay can see the marker. It owns no gesture
      // recognizer, so taps, drags and scrolls pass through unchanged.
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }
}

class _ClickerRecognizer extends OneSequenceGestureRecognizer {
  _ClickerRecognizer();

  Duration Function()? getDuration;
  void Function(Offset position)? onTrigger;
  void Function(Offset position)? onPressStart;
  VoidCallback? onPressEnd;

  Timer? _timer;
  Offset? _downPosition;
  bool _tracking = false;
  bool _resolved = false;

  @override
  String get debugDescription => 'clicker';

  @override
  void didStopTrackingLastPointer(int pointer) {}

  void _settleAccepted() {
    if (_resolved) return;
    _resolved = true;
    resolve(GestureDisposition.accepted);
  }

  void _settleRejected() {
    if (_resolved) return;
    _resolved = true;
    resolve(GestureDisposition.rejected);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_tracking) return;
    _tracking = true;
    _resolved = false;
    _downPosition = event.position;
    super.addAllowedPointer(event);
    try {
      onPressStart?.call(event.position);
    } catch (_) {}
    _timer?.cancel();
    final duration = getDuration?.call() ?? const Duration(seconds: 2);
    _timer = Timer(duration, () {
      if (_resolved) return;
      _settleAccepted();
      try {
        onPressEnd?.call();
      } catch (_) {}
      final pos = _downPosition;
      if (pos != null) onTrigger?.call(pos);
    });
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      final down = _downPosition;
      if (down != null && (event.position - down).distance > 24) {
        _timer?.cancel();
        _timer = null;
        _tracking = false;
        try {
          onPressEnd?.call();
        } catch (_) {}
        _settleRejected();
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _timer?.cancel();
      _timer = null;
      _settleRejected();
      _tracking = false;
      try {
        onPressEnd?.call();
      } catch (_) {}
    }
  }

  @override
  void rejectGesture(int pointer) {
    _resolved = true;
    _timer?.cancel();
    _timer = null;
    _tracking = false;
    try {
      onPressEnd?.call();
    } catch (_) {}
    super.rejectGesture(pointer);
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class InformationClickerOverlay extends ConsumerStatefulWidget {
  final Widget child;
  const InformationClickerOverlay({super.key, required this.child});

  @override
  ConsumerState<InformationClickerOverlay> createState() =>
      _InformationClickerOverlayState();
}

class _InformationClickerOverlayState
    extends ConsumerState<InformationClickerOverlay> {
  final GlobalKey<OverlayState> _overlayKey = GlobalKey<OverlayState>();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _progressDelay?.cancel();
    _progressDelay = null;
    _hideProgress();
    _removeEntry();
    super.dispose();
  }

  OverlayEntry? _progressEntry;
  Timer? _progressDelay;

  /// How long the finger may rest on the screen before the progress border
  /// starts drawing. A normal tap releases well before this, so quick taps no
  /// longer flash a red border around whatever they touched.
  static const Duration _pressGrace = Duration(milliseconds: 350);

  String _currentRoute() {
    try {
      return ref.read(goRouterProvider).state.uri.toString();
    } catch (_) {
      return '';
    }
  }

  bool _isArabic() {
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

  /// Decides whether a press may show anything, and WHICH label explains it.
  /// Returns null when the press must stay completely quiet. When the press
  /// lands on a big section card with no curated label of its own, the
  /// effective label is forced to '' so the card renders the section's
  /// curated content — never the raw record text.
  ({bool allow, String label, Rect? rect})? _decide(Offset anchor) {
    if (!mounted) return null;
    final view = View.of(context);
    // Quiet zones (transaction rows, chat bubbles…) opt out entirely:
    // their long-press belongs to a native action, never to the clicker.
    if (_isQuietAt(anchor, view.viewId)) return null;
    if (_isEditableAt(anchor, view.viewId)) return null;
    final route = _currentRoute();
    final arabic = _isArabic();
    final resolved = _resolveTarget(anchor, view.viewId, arabic);
    if (HelpAllowlist.allows(
        route: route, label: resolved.label, arabic: arabic)) {
      return (
        allow: true,
        label: resolved.label,
        rect: resolved.rect,
      );
    }
    final fallbackRect =
        resolved.rect ?? _targetRectAt(anchor, view.viewId);
    if (HelpAllowlist.allowsSectionCard(
        route: route, rect: fallbackRect)) {
      return (allow: true, label: '', rect: fallbackRect);
    }
    return null;
  }

  void _showProgress(Offset anchor) {
    if (!mounted || _entry != null || _progressEntry != null) return;
    if (_progressDelay != null) return;
    final settings = ref.read(helpClickerProvider);
    if (!settings.enabled) return;
    final decision = _decide(anchor);
    if (decision == null) return;
    final view = View.of(context);
    final rect = decision.rect ??
        _targetRectAt(anchor, view.viewId) ??
        Rect.fromCenter(center: anchor, width: 76, height: 76);
    final total = settings.seconds * 1000;
    // Elapsed-time progress: the controller runs on the FULL press duration
    // and starts at the fraction already spent inside the grace window, so
    // the border completes at exactly the same instant the trigger fires —
    // one shared time source, no Future/Timer drift between them.
    final startAt =
        (_pressGrace.inMilliseconds / total).clamp(0.0, 1.0);
    _progressDelay = Timer(_pressGrace, () {
      _progressDelay = null;
      if (!mounted || _entry != null || _progressEntry != null) return;
      final entry = OverlayEntry(
        builder: (_) => Positioned.fill(
          child: IgnorePointer(
            child: _ProgressBorder(
              target: rect,
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
    if (_entry != null) return;
    if (!mounted) return;
    final settings = ref.read(helpClickerProvider);
    if (!settings.enabled) {
      _hideProgress();
      return;
    }
    final route = _currentRoute();
    final arabic = _isArabic();
    final decision = _decide(anchor);
    if (decision == null) {
      _hideProgress();
      return;
    }
    final info = HelpExplain.resolve(
        route: route, label: decision.label, arabic: arabic);
    final media = MediaQuery.of(context);
    _hideProgress();
    _removeEntry();
    final entry = OverlayEntry(
      builder: (_) => _SpotlightHost(
        anchor: anchor,
        target: decision.rect,
        info: info,
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

  bool _isQuietAt(Offset position, int viewId) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, position, viewId);
      return result.path.any((e) =>
          e.target is RenderMetaData &&
          (e.target as RenderMetaData).metaData == _kClickerQuietTag);
    } catch (_) {
      return false;
    }
  }

  bool _isEditableAt(Offset position, int viewId) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, position, viewId);
      return result.path.any((e) => e.target is RenderEditable);
    } catch (_) {
      return false;
    }
  }

  Rect? _targetRectAt(Offset position, int viewId) {
    try {
      final size = MediaQuery.of(context).size;
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, position, viewId);
      for (final entry in result.path) {
        final target = entry.target;
        if (target is! RenderBox || !target.attached || !target.hasSize) {
          continue;
        }
        if (target is RenderParagraph || target is RenderEditable) continue;
        final boxSize = target.size;
        if (boxSize.width < 10 || boxSize.height < 10) continue;
        if (boxSize.width > size.width * 0.96 &&
            boxSize.height > size.height * 0.96) {
          continue;
        }
        Offset local;
        try {
          local = target.globalToLocal(position);
        } catch (_) {
          continue;
        }
        if (local.dx < -6 ||
            local.dy < -6 ||
            local.dx > boxSize.width + 6 ||
            local.dy > boxSize.height + 6) {
          continue;
        }
        Offset origin;
        try {
          origin = target.localToGlobal(Offset.zero);
        } catch (_) {
          continue;
        }
        final rect = origin & boxSize;
        if (rect.width <= 0 || rect.height <= 0) continue;
        return rect;
      }
    } catch (_) {}
    return null;
  }

  ({Rect? rect, String label}) _resolveTarget(
      Offset position, int viewId, bool arabic) {
    try {
      final size = MediaQuery.of(context).size;
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, position, viewId);
      String label = '';
      Rect? frame;
      var levels = 0;
      for (final entry in result.path) {
        if (levels >= 6) break;
        final target = entry.target;
        if (target is! RenderBox || !target.attached || !target.hasSize) {
          continue;
        }
        if (target is RenderParagraph || target is RenderEditable) continue;
        final boxSize = target.size;
        if (boxSize.width < 10 || boxSize.height < 10) continue;
        if (boxSize.width > size.width * 0.7 &&
            boxSize.height > size.height * 0.4) {
          continue;
        }
        Offset local;
        try {
          local = target.globalToLocal(position);
        } catch (_) {
          continue;
        }
        if (local.dx < -6 ||
            local.dy < -6 ||
            local.dx > boxSize.width + 6 ||
            local.dy > boxSize.height + 6) {
          continue;
        }
        Offset origin;
        try {
          origin = target.localToGlobal(Offset.zero);
        } catch (_) {
          continue;
        }
        final rect = origin & boxSize;
        if (rect.width <= 0 || rect.height <= 0) continue;
        levels++;
        final texts = _collectTexts(target);
        if (texts.isEmpty) continue;
        if (label.isEmpty) {
          label = _chooseLabel(texts, arabic: arabic);
          frame = rect;
        } else {
          final compatible =
              texts.every((t) => t == label || !_hasLetters(t));
          if (compatible) {
            frame = rect;
          } else {
            break;
          }
        }
      }
      return (rect: frame, label: label);
    } catch (_) {}
    return (rect: null, label: '');
  }

  List<String> _collectTexts(RenderObject root) {
    final out = <String>[];
    void visit(RenderObject o) {
      if (o is RenderParagraph) {
        final text = _paragraphText(o);
        if (text != null && text.isNotEmpty) out.add(text);
        return;
      }
      try {
        o.visitChildren(visit);
      } catch (_) {}
    }

    try {
      visit(root);
    } catch (_) {}
    return out;
  }

  String _chooseLabel(List<String> texts, {required bool arabic}) {
    for (final t in texts) {
      if (HelpContent.hasExactLabel(t, arabic: arabic)) return t;
    }
    String best = '';
    for (final t in texts) {
      if (!_hasLetters(t)) continue;
      if (t.length > best.length) best = t;
    }
    if (best.isNotEmpty) return best;
    for (final t in texts) {
      if (t.trim().length >= 2 && t.length > best.length) best = t;
    }
    return best;
  }

  bool _hasLetters(String s) =>
      RegExp(r'[A-Za-z\u0600-\u06FF]').hasMatch(s);

  String? _paragraphText(RenderParagraph p) {
    try {
      final span = p.text;
      String? family;
      span.visitChildren((s) {
        if (family == null && s is TextSpan && s.style?.fontFamily != null) {
          family = s.style!.fontFamily;
        }
        return true;
      });
      final f = family ?? '';
      if (f.contains('Icon') ||
          f.contains('Material') ||
          f.contains('Phosphor') ||
          f.contains('Huge')) {
        return null;
      }
      final text = span.toPlainText().trim();
      if (text.isEmpty) return null;
      final runes = text.runes.toList();
      final privateUse = runes
          .where((r) => (r >= 0xE000 && r <= 0xF8FF) || r >= 0xF0000)
          .length;
      if (privateUse > 0 && privateUse >= (runes.length / 2).ceil()) {
        return null;
      }
      final hasLetters = RegExp(r'[A-Za-z\u0600-\u06FF]').hasMatch(text);
      if (!hasLetters && text.length < 3) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch settings so the persisted duration is loaded long before the
    // first press (the trigger timer must read the USER value, never the
    // just-built default) and the overlay follows on/off changes.
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
  final Rect? target;
  final HelpExplainData info;
  final bool arabic;
  final Size screenSize;
  final EdgeInsets padding;
  final VoidCallback onClose;

  const _SpotlightHost({
    required this.anchor,
    required this.target,
    required this.info,
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
    final targetCenterX =
        (target?.center.dx ?? widget.anchor.dx).clamp(0.0, screenW);
    final targetTop = target?.top ?? (widget.anchor.dy - 24);
    final targetBottom = target?.bottom ?? (widget.anchor.dy + 24);

    final hole = target?.inflate(7);
    final cardWidth = (screenW - 32).clamp(200.0, 360.0);
    final cardLeft = (targetCenterX - cardWidth / 2)
        .clamp(16.0, (screenW - cardWidth - 16).clamp(16.0, screenW));
    final spaceAbove = targetTop - topLimit - 18;
    final spaceBelow = bottomLimit - targetBottom - 18;
    final showAbove = spaceAbove >= 250 || spaceAbove >= spaceBelow;
    final available = (showAbove ? spaceAbove : spaceBelow).clamp(190.0, 430.0);

    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
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
              bottom:
                  showAbove ? screenH - targetTop + 16 : null,
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
                      info: widget.info,
                      arabic: widget.arabic,
                      tailDown: showAbove,
                      tailX: (targetCenterX - cardLeft).clamp(36.0, cardWidth - 36.0),
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
    if (hole != null && !hole!.isEmpty) {
      path.addRRect(RRect.fromRectAndRadius(hole!, const Radius.circular(22)));
      path.fillType = PathFillType.evenOdd;
    }
    canvas.drawPath(path, Paint()..color = Colors.black.withAlpha(dimAlpha));
    if (hole != null && !hole!.isEmpty) {
      final frame = RRect.fromRectAndRadius(hole!, const Radius.circular(22));
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

class _SpotCard extends StatelessWidget {
  final HelpExplainData info;
  final bool arabic;
  final bool tailDown;
  final double tailX;
  final VoidCallback onClose;

  const _SpotCard({
    required this.info,
    required this.arabic,
    required this.tailDown,
    required this.tailX,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final align = arabic ? TextAlign.right : TextAlign.left;
    final dir = arabic ? TextDirection.rtl : TextDirection.ltr;
    return DefaultTextStyle(
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
            top: tailDown ? 14 : 20,
            bottom: tailDown ? 22 : 14,
            left: 16,
            right: 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                textDirection: dir,
                children: [
                  Expanded(
                    child: Text(
                      info.title,
                      textAlign: align,
                      softWrap: true,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        decoration: TextDecoration.none,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: onClose,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withAlpha(14),
                        border: Border.all(
                            color: Colors.white.withAlpha(60)),
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 15, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                info.body,
                textAlign: align,
                softWrap: true,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  decoration: TextDecoration.none,
                  fontSize: 12.5,
                  height: 1.6,
                  color: Color(0xFFD9D9D9),
                ),
              ),
              const SizedBox(height: 10),
              // Items without a real flow show description only — never a
              // filler "how to use" block.
              if (info.steps.isNotEmpty)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  textDirection: dir,
                  children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                          alignment: align == TextAlign.right
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 13, vertical: 6),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFFE0393E), _kRedDeep],
                                begin: Alignment.topRight,
                                end: Alignment.bottomLeft,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              arabic ? 'طريقة الاستخدام:' : 'How to use:',
                              softWrap: true,
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
                        ...info.steps.asMap().entries.map((entry) {
                          final index = entry.key;
                          final step = entry.value;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              textDirection: dir,
                              children: [
                                Container(
                                  width: 25,
                                  height: 25,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _kRed,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${index + 1}',
                                    style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      decoration: TextDecoration.none,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Padding(
                                    padding:
                                        const EdgeInsets.only(top: 2),
                                    child: Text(
                                      step,
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
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _FloatingBadge(info: info),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingBadge extends StatefulWidget {
  final HelpExplainData info;
  const _FloatingBadge({required this.info});

  @override
  State<_FloatingBadge> createState() => _FloatingBadgeState();
}

class _FloatingBadgeState extends State<_FloatingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: 78,
      height: 94,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF3A0B10), Color(0xFF120304)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border.all(color: _kRed.withAlpha(110)),
        boxShadow: [
          BoxShadow(
            color: _kRed.withAlpha(70),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: widget.info.asset != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Image.asset(
                widget.info.asset!,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
              ),
            )
          : Icon(widget.info.icon,
              size: 40, color: widget.info.iconColor),
    );
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        final wave = math.sin(_controller.value * 2 * math.pi);
        return Transform.translate(
          offset: Offset(0, wave * 3),
          child: Transform.scale(
            scale: 1 + wave * 0.015,
            child: child,
          ),
        );
      },
      child: badge,
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
      Rect.fromLTWH(2, tailDown ? 2 : 16, w - 4, h - (tailDown ? 18 : 18) - 2),
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
  final Rect target;

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
      builder: (_, __) => CustomPaint(
        painter: _ProgressBorderPainter(
          rect: widget.target,
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
    final hole = rect.inflate(6);
    final frame = RRect.fromRectAndRadius(hole, const Radius.circular(22));
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
