import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import '../../../../core/theme/app_colors.dart';

enum SaraVisualState { ready, thinking, typing, executing, success, error }

/// The original portrait, with lighting painted independently from the photo.
class SaraPremiumAvatar extends StatefulWidget {
  const SaraPremiumAvatar({super.key, this.size = 40, this.state = SaraVisualState.ready, this.business = false, this.onTap});
  final double size;
  final SaraVisualState state;
  final bool business;
  final VoidCallback? onTap;
  @override
  State<SaraPremiumAvatar> createState() => _SaraPremiumAvatarState();
}

class _SaraPremiumAvatarState extends State<SaraPremiumAvatar> with TickerProviderStateMixin {
  late final _light = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600))..repeat();
  late final _spring = AnimationController.unbounded(vsync: this, value: 1);
  Offset _tilt = Offset.zero;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) { _light.stop(); }
    else if (!_light.isAnimating) { _light.repeat(); }
  }
  @override
  void dispose() { _light.dispose(); _spring.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return RepaintBoundary(child: GestureDetector(
      onTap: () {
        widget.onTap?.call();
        if (!reduced) _spring.animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 240, damping: 15), .88, 1, 0));
      },
      onPanUpdate: (d) => setState(() => _tilt = Offset((_tilt.dx + d.delta.dx / 140).clamp(-.10, .10), (_tilt.dy + d.delta.dy / 140).clamp(-.10, .10))),
      onPanEnd: (_) => setState(() => _tilt = Offset.zero),
      child: AnimatedBuilder(animation: Listenable.merge([_light, _spring]), builder: (context, _) {
        final phase = reduced ? 0.0 : _light.value;
        final breathe = reduced ? 1.0 : 1 + math.sin(phase * math.pi * 2) * (widget.business ? .008 : .014);
        return Transform(alignment: Alignment.center,
          transform: Matrix4.identity()..setEntry(3, 2, .001)..rotateX(_tilt.dy)..rotateY(-_tilt.dx)..scale(_spring.value * breathe),
          child: CustomPaint(foregroundPainter: _SaraHalo(phase, widget.state), child: Container(
            width: widget.size, height: widget.size, padding: EdgeInsets.all(widget.size * .045),
            decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(45), blurRadius: widget.size * .33, offset: Offset(0, widget.size * .08))]),
            child: ClipOval(child: Image.asset('assets/images/sara_avatar.jpg', fit: BoxFit.cover, gaplessPlayback: true)),
          )),
        );
      }),
    ));
  }
}

class _SaraHalo extends CustomPainter {
  _SaraHalo(this.phase, this.state);
  final double phase;
  final SaraVisualState state;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * .49;
    final active = state != SaraVisualState.ready;
    final color = state == SaraVisualState.success ? const Color(0xFF39836A) : AppColors.primary;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(center, radius, Paint()..style = PaintingStyle.stroke..strokeWidth = active ? 1.8 : 1
      ..shader = SweepGradient(transform: GradientRotation(phase * math.pi * 2), colors: [color.withAlpha(20), color.withAlpha(active ? 230 : 110), Colors.white.withAlpha(170), color.withAlpha(20)]).createShader(rect));
    if (active) {
      for (var i = 0; i < 2; i++) {
        final t = (phase + i * .5) % 1;
        canvas.drawCircle(center, radius + size.width * .10 * t, Paint()..color = color.withAlpha(((1 - t) * 45).round())..style = PaintingStyle.stroke..strokeWidth = 1);
      }
    }
  }
  @override
  bool shouldRepaint(_SaraHalo old) => old.phase != phase || old.state != state;
}

class SaraIntelligentHeader extends StatelessWidget {
  const SaraIntelligentHeader({super.key, required this.avatarKey, required this.state, required this.arabic,
    required this.hidden, required this.business, this.name, this.onAvatarTap, this.onBack});
  final GlobalKey avatarKey;
  final SaraVisualState state;
  final bool arabic, hidden, business;
  final String? name;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context) {
    final labels = arabic ? const ['متصل', 'سارة تفكر…', 'سارة تكتب…', 'جاري التنفيذ…', 'تم التنفيذ', 'تعذر إتمام الطلب']
        : const ['Online', 'Sara is thinking…', 'Sara is writing…', 'Executing…', 'Completed', 'Unable to complete'];
    return ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: DecoratedBox(decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withAlpha(210), borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withAlpha(22))),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), child: Row(textDirection: TextDirection.ltr, children: [
          if (onBack != null) IconButton(onPressed: onBack, tooltip: arabic ? 'رجوع' : 'Back',
              icon: const Icon(Icons.arrow_back_rounded, textDirection: TextDirection.ltr),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44)),
          Expanded(child: Row(textDirection: arabic ? TextDirection.rtl : TextDirection.ltr, children: [
          SizedBox(key: avatarKey, width: 40, height: 40, child: Opacity(opacity: hidden ? 0 : 1,
            child: SaraPremiumAvatar(state: state, business: business, onTap: onAvatarTap))),
          const SizedBox(width: 12),
          Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name ?? (arabic ? 'سارة' : 'Sara'), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Row(children: [Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF459D74), shape: BoxShape.circle)),
              const SizedBox(width: 6), Flexible(child: AnimatedSwitcher(duration: const Duration(milliseconds: 220),
                child: Text(labels[state.index], key: ValueKey(state), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)))),
            ]),
          ])),
          ])),
        ])),
      ),
    ));
  }
}

/// One actual image travels from the center to the measured header rectangle.
/// The underlying portrait stays transparent until this widget completes.
class SaraFirstEncounter extends StatefulWidget {
  const SaraFirstEncounter({super.key, required this.targetKey, required this.arabic, required this.onComplete});
  final GlobalKey targetKey;
  final bool arabic;
  final VoidCallback onComplete;
  @override
  State<SaraFirstEncounter> createState() => _SaraFirstEncounterState();
}

class _SaraFirstEncounterState extends State<SaraFirstEncounter> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));
  Rect? _destination;
  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((s) { if (s == AnimationStatus.completed && mounted) widget.onComplete(); });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = widget.targetKey.currentContext?.findRenderObject();
      final origin = context.findRenderObject();
      if (target is RenderBox && origin is RenderBox && target.hasSize) {
        setState(() => _destination = origin.globalToLocal(target.localToGlobal(Offset.zero)) & target.size);
      }
      if (MediaQuery.of(context).disableAnimations) {
        widget.onComplete();
      } else { _controller.forward(); }
    });
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Semantics(label: widget.arabic ? 'ترحيب سارة، المس للتخطي' : 'Sara welcome. Tap to skip',
    child: GestureDetector(behavior: HitTestBehavior.opaque,
      onTap: () => _controller.animateTo(1, duration: const Duration(milliseconds: 180), curve: Curves.easeOutCubic),
      child: LayoutBuilder(builder: (context, box) => AnimatedBuilder(animation: _controller, builder: (context, _) {
        final t = _controller.value;
        final move = Curves.easeInOutCubic.transform(((t - .61) / .39).clamp(0.0, 1.0));
        final fade = (t / .14).clamp(0.0, 1.0) * (1 - move);
        final diameter = math.min(box.maxWidth * .44, 190.0);
        final start = Rect.fromCenter(center: Offset(box.maxWidth / 2, box.maxHeight * .39), width: diameter, height: diameter);
        final rect = Rect.lerp(start, _destination ?? start, move)!;
        final words = (widget.arabic ? 'أهلًا بك، أنا سارة ✨ جاهزة أساعدك في كل خطوة.' : 'Welcome, I’m Sara ✨ Ready to help you every step.').split(' ');
        final count = (((t - .16) / .40).clamp(0.0, 1.0) * words.length).ceil();
        return Stack(children: [
          Positioned.fill(child: ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 2 * fade, sigmaY: 2 * fade),
            child: ColoredBox(color: Colors.black.withAlpha((115 * fade).round()))))),
          Positioned.fromRect(rect: rect, child: Opacity(opacity: (t / .10).clamp(0.0, 1.0),
            child: IgnorePointer(child: SaraPremiumAvatar(size: rect.width, state: move < .9 ? SaraVisualState.thinking : SaraVisualState.ready)))),
          Positioned(top: start.bottom + 30, left: 28, right: 28, child: Opacity(opacity: fade,
            child: Text(words.take(count).join(' '), textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.w600, height: 1.8, color: Colors.white)))),
        ]);
      })),
    ));
}

class SaraWordReveal extends StatefulWidget {
  const SaraWordReveal({super.key, required this.text, required this.style, required this.direction,
    required this.animate, this.onComplete, this.onProgress, this.onStart});
  final String text;
  final TextStyle style;
  final TextDirection direction;
  final bool animate;
  final VoidCallback? onComplete, onProgress, onStart;
  @override
  State<SaraWordReveal> createState() => _SaraWordRevealState();
}

class _SaraWordRevealState extends State<SaraWordReveal> {
  Timer? _timer;
  late List<String> _words;
  int _visible = 0;
  bool _finished = false;
  @override
  void initState() {
    super.initState();
    _words = RegExp(r'\S+\s*').allMatches(widget.text).map((m) => m[0]!).toList();
    _visible = widget.animate ? 0 : _words.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.animate || MediaQuery.of(context).disableAnimations || _words.isEmpty) { _finish(); return; }
      widget.onStart?.call();
      final step = math.max(1, (_words.length / 85).ceil());
      final interval = (1600 / math.max(1, _words.length / step)).clamp(24, 85).round();
      _timer = Timer.periodic(Duration(milliseconds: interval), (_) {
        if (!mounted) return;
        setState(() => _visible = math.min(_visible + step, _words.length));
        widget.onProgress?.call();
        if (_visible >= _words.length) _finish();
      });
    });
  }
  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    _timer?.cancel();
    setState(() => _visible = _words.length);
    widget.onComplete?.call();
  }
  @override
  void dispose() {
    _timer?.cancel();
    if (!_finished && widget.animate) WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete?.call());
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: _finish,
    child: AnimatedSize(duration: const Duration(milliseconds: 90), alignment: AlignmentDirectional.topStart,
      child: Text.rich(TextSpan(children: [
        TextSpan(text: _visible >= _words.length ? widget.text : _words.take(_visible).join()),
        if (_visible < _words.length) WidgetSpan(alignment: PlaceholderAlignment.middle,
          child: Padding(padding: const EdgeInsetsDirectional.only(start: 4), child: SizedBox(width: 5, height: 13,
            child: DecoratedBox(decoration: BoxDecoration(color: AppColors.primary.withAlpha(145), borderRadius: BorderRadius.circular(3)))))),
      ]), textDirection: widget.direction, style: widget.style),
    ));
}

class SaraPressable extends StatefulWidget {
  const SaraPressable({super.key, required this.child});
  final Widget child;
  @override
  State<SaraPressable> createState() => _SaraPressableState();
}
class _SaraPressableState extends State<SaraPressable> {
  bool _down = false;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => setState(() => _down = true),
    onPointerUp: (_) => setState(() => _down = false),
    onPointerCancel: (_) => setState(() => _down = false),
    child: AnimatedScale(scale: _down ? .965 : 1, duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutBack, child: widget.child));
}
