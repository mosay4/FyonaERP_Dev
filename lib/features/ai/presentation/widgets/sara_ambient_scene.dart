import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'sara_ambient_controller.dart';

/// One runtime program shared by chats; each scene owns its mutable uniforms.
class SaraFluidProgram {
  static const asset = 'assets/shaders/sara_fluid.frag.sprv';
  static Future<ui.FragmentProgram>? _loading;
  static Future<ui.FragmentProgram> load() =>
      _loading ??= ui.FragmentProgram.fromAsset(asset);
}

/// Full-bleed GPU aurora. The ticker only invalidates painting, never chat UI,
/// and it only runs while something happens (entrance, focus, typing,
/// sending, thinking, a streaming reply, an operation) plus a short settle:
/// when the chat is idle the last frame stays on screen and no frame is
/// scheduled (battery, and `pumpAndSettle` in tests).
class SaraAmbientScene extends StatefulWidget {
  const SaraAmbientScene({
    super.key,
    required this.controller,
    required this.activity,
    required this.inputKey,
    required this.avatarKey,
    required this.userKey,
    required this.replyKey,
    this.enabled = true,
    this.business = false,
  });
  final SaraAmbientController controller;
  final SaraAmbientActivity activity;
  final GlobalKey inputKey, avatarKey, userKey, replyKey;
  final bool enabled, business;
  @override
  State<SaraAmbientScene> createState() => _SaraAmbientSceneState();
}

class _SaraAmbientSceneState extends State<SaraAmbientScene>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  Duration _lastTick = Duration.zero;
  bool _appActive = true, _scheduled = false, _dependenciesActive = true;
  bool _painting = false;
  // Controller time (seconds) until which the scene keeps moving after the
  // last real event, so motion eases out instead of freezing mid-flow.
  double _awakeUntil = 0;
  static const _settle = 1.8, _entrance = 2.4;
  int _revision = -1;
  Size? _size;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_event);
    _awakeUntil = widget.controller.time + _entrance;
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await SaraFluidProgram.load();
      if (!mounted) return;
      setState(() {
        _shader = program.fragmentShader();
      });
    } catch (error, stack) {
      if (!mounted) return;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Sara GPU fluid',
          context: ErrorDescription('loading ${SaraFluidProgram.asset}'),
        ),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dependenciesActive =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    widget.controller.setReducedMotion(
      MediaQuery.of(context).disableAnimations,
    );
    _synchronize();
    _measureSoon();
  }

  @override
  void didUpdateWidget(SaraAmbientScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      oldWidget.controller == widget.controller,
      'Each scene owns one chat-scoped visual controller.',
    );
    _synchronize();
    _measureSoon();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _synchronize();
  }

  void _synchronize() {
    if (!mounted) return;
    final c = widget.controller;
    final active = widget.enabled && _appActive && _dependenciesActive;
    final wasVisible = c.visible;
    c.setVisible(active);
    if (active && !wasVisible) _awakeUntil = c.time + _entrance;
    if (active) c.setActivity(widget.activity);
    if (active && c.canAnimate && (c.active || c.time < _awakeUntil)) {
      if (!_ticker.isActive) {
        _lastTick = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _event() {
    if (!mounted) return;
    if (!_painting) {
      // A real event (typing, focus, send, reply words, phase change…).
      _awakeUntil = widget.controller.time + _settle;
      if (!_ticker.isActive) _synchronize();
    }
    if (widget.controller.layoutRevision != _revision) {
      _revision = widget.controller.layoutRevision;
      _measureSoon();
    }
  }

  void _tick(Duration elapsed) {
    final c = widget.controller;
    c.advance(elapsed - _lastTick);
    _lastTick = elapsed;
    if (c.phase == SaraAmbientPhase.responding ||
        c.phase == SaraAmbientPhase.completed) {
      _measureSoon();
    }
    _painting = true;
    try {
      c.paintFrame();
    } finally {
      _painting = false;
    }
    // Idle and settled: keep the last frame, schedule nothing more.
    if (!c.active && c.time >= _awakeUntil && _ticker.isActive) _ticker.stop();
  }

  void _measureSoon() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final origin = context.findRenderObject();
      if (origin is! RenderBox || !origin.hasSize || !origin.attached) return;
      Rect? rect(GlobalKey key) {
        final box = key.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.hasSize || !box.attached) return null;
        final point = origin.globalToLocal(box.localToGlobal(Offset.zero));
        if (!point.dx.isFinite || !point.dy.isFinite) return null;
        return point & box.size;
      }

      widget.controller.setGeometry(
        SaraAmbientGeometry(
          input: rect(widget.inputKey),
          avatar: rect(widget.avatarKey),
          user: rect(widget.userKey),
          reply: rect(widget.replyKey),
        ),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_event);
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, box) {
            if (_size != box.biggest) {
              _size = box.biggest;
              _measureSoon();
            }
            final theme = Theme.of(context);
            return CustomPaint(
              painter: SaraAmbientPainter(
                controller: widget.controller,
                primary: theme.colorScheme.primary,
                ink: theme.colorScheme.onSurface,
                dark: theme.brightness == Brightness.dark,
                business: widget.business,
                shader: _shader,
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Existing edge-only input/reply accents stay separate from the background.
class SaraAmbientAccents extends StatelessWidget {
  const SaraAmbientAccents({
    super.key,
    required this.controller,
    this.business = false,
  });
  final SaraAmbientController controller;
  final bool business;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: SaraAmbientPainter(
              controller: controller,
              primary: theme.colorScheme.primary,
              ink: theme.colorScheme.onSurface,
              dark: theme.brightness == Brightness.dark,
              business: business,
              accents: true,
            ),
          ),
        ),
      ),
    );
  }
}

class SaraAmbientPainter extends CustomPainter {
  SaraAmbientPainter({
    required this.controller,
    required this.primary,
    required this.ink,
    required this.dark,
    this.business = false,
    this.accents = false,
    this.shader,
  }) : super(repaint: controller);
  final SaraAmbientController controller;
  final Color primary, ink;
  final bool dark, business, accents;
  final ui.FragmentShader? shader;

  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.visible ||
        size.isEmpty ||
        !size.width.isFinite ||
        !size.height.isFinite) {
      return;
    }
    if (accents) {
      // Calm design: no coloured edges; only a whisper of focus on input.
      _focus(canvas, size);
      return;
    }
    _calm(canvas, size);
    return;
    // ignore: dead_code
    final effect = shader;
    // Loading is asynchronous. No CPU/static substitute is rendered meanwhile.
    if (effect == null) return;
    var index = 0;
    void value(double v) => effect.setFloat(index++, v);
    void geometry(Rect? rect, Rect fallback) {
      final r = rect ?? fallback;
      value((r.center.dx / size.width).clamp(0, 1));
      value((r.center.dy / size.height).clamp(0, 1));
      value((r.width / size.width / 2).clamp(0, 1));
      value((r.height / size.height / 2).clamp(0, 1));
    }

    final c = controller, g = c.geometry;
    value(c.time);
    value(size.width);
    value(size.height);
    geometry(g.avatar, Rect.fromLTWH(size.width * .15, 0, 40, 40));
    geometry(
      g.input,
      Rect.fromLTWH(
        size.width * .1,
        size.height * .90,
        size.width * .8,
        size.height * .07,
      ),
    );
    geometry(
      g.user,
      Rect.fromLTWH(
        size.width * .55,
        size.height * .24,
        size.width * .4,
        size.height * .1,
      ),
    );
    geometry(
      g.reply,
      Rect.fromLTWH(
        size.width * .05,
        size.height * .36,
        size.width * .7,
        size.height * .2,
      ),
    );
    value(c.typingAmp);
    value(c.sendImpulse);
    value(c.thinkingFocus);
    value(c.respondFlow);
    value(c.revealPulse);
    value(c.completedBalance);
    value(dark ? 1 : 0);
    value(business ? 1 : 0);
    value(c.fluidFlow);
    value(c.fluidSendProgress);
    canvas.drawRect(Offset.zero & size, Paint()..shader = effect);
  }

  /// The calm background: a soft gradient in the theme's own tones and
  /// faint light that reacts gently — it breathes behind Sara's portrait
  /// while she thinks, warms above the input while typing, and softly
  /// washes behind her reply as it arrives. No swirls, no strong colours.
  void _calm(Canvas canvas, Size size) {
    final c = controller, g = c.geometry;
    final w = size.width, h = size.height;
    final rect = Offset.zero & size;
    final base = dark ? const Color(0xFF15161A) : const Color(0xFFF4F2F4);
    final tint = Color.alphaBlend(
      primary.withValues(alpha: dark ? .07 : .045),
      base,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tint, base, base],
          stops: const [0, .45, 1],
        ).createShader(rect),
    );
    void glow(Offset centre, double radius, Color color, double alpha) {
      if (alpha <= .002) return;
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha.clamp(0, .22)),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: centre, radius: radius)),
      );
    }

    final breathe = c.reducedMotion ? 1.0 : .75 + .25 * math.sin(c.time * 1.4);
    // Behind Sara while she thinks (a slow, soft breath).
    final avatar = g.avatar?.center ?? Offset(w * .8, 0);
    glow(
      Offset(avatar.dx, math.max(0, avatar.dy)),
      w * .62,
      primary,
      (dark ? .06 : .04) + c.thinkingFocus * (dark ? .10 : .07) * breathe,
    );
    // A cool counter-light so the page never reads as «all red».
    glow(
      Offset(w * .08, h * .55),
      w * .7,
      dark ? const Color(0xFF6A6F8F) : const Color(0xFFB9C2D6),
      dark ? .05 : .08,
    );
    // Above the input while typing / on send.
    final input = g.input?.center ?? Offset(w / 2, h * .93);
    glow(
      input,
      w * .55,
      primary,
      c.typingAmp * (dark ? .07 : .05) + c.sendImpulse * .06,
    );
    // Behind the reply as it streams, fading after.
    final reply = g.reply?.center;
    if (reply != null) {
      glow(reply, w * .5, primary, c.respondFlow * (dark ? .06 : .04));
    }
  }

  void _focus(Canvas canvas, Size size) {
    final c = controller, g = c.geometry;
    if (g.input != null && c.focusGlow > .001) {
      _outline(canvas, size, g.input!, .08 * c.focusGlow, 3);
    }
  }

  // ignore: unused_element
  void _edges(Canvas canvas, Size size) {
    final c = controller, g = c.geometry;
    if (g.input != null && c.focusGlow > .001) {
      final pulse = c.reducedMotion ? 0.0 : c.typingEnergy * .03 * math.sin(c.time * 5);
      _outline(
        canvas,
        size,
        g.input!,
        (.10 + pulse + c.typingEnergy * .10) * c.focusGlow,
        3 + c.typingEnergy * 3 * (1 + c.contraction * .4),
      );
      if (!c.reducedMotion && c.focusProgress < 1) {
        _outline(canvas, size, g.input!, .07 * (1 - c.focusProgress), 2 + c.focusProgress * 10);
      }
    }
    if (g.input != null && c.phase == SaraAmbientPhase.error && !c.reducedMotion) {
      final p = (c.phaseAge / .30).clamp(0.0, 1.0);
      _outline(canvas, size, g.input!, .06 * math.sin(p * math.pi), 6 * (1 - p));
    }
    if (g.reply != null &&
        const {
          SaraAmbientPhase.responding,
          SaraAmbientPhase.completed,
          SaraAmbientPhase.success,
        }.contains(c.phase)) {
      final fade = c.phase == SaraAmbientPhase.responding
          ? .045 + c.wordEnergy * .05
          : .10 * (1 - (c.phaseAge / .5).clamp(0, 1));
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          0,
          0,
          size.width,
          ((g.input?.top ?? size.height) - 8).clamp(0, size.height),
        ),
      );
      _outline(canvas, size, g.reply!, fade, 2 + c.wordEnergy * 2);
      canvas.restore();
    }
  }

  void _outline(
    Canvas canvas,
    Size size,
    Rect rect,
    double alpha,
    double spread,
  ) {
    canvas.save();
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(24)));
    canvas.clipPath(mask);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.inflate(spread), const Radius.circular(26)),
      Paint()
        ..color = primary.withValues(alpha: alpha.clamp(0, .23))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(SaraAmbientPainter old) =>
      old.shader != shader ||
      old.primary != primary ||
      old.ink != ink ||
      old.dark != dark ||
      old.business != business ||
      old.accents != accents ||
      old.controller != controller;
}
