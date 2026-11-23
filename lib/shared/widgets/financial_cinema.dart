import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

enum FinancialScene {
  sales,
  treasury,
  inventory,
  debts,
  executive,
  precision,
  balance,
}

class FinancialCue {
  final AudioPlayer _player = AudioPlayer();
  bool _closed = false;
  static const channel = MethodChannel('fyona/motion_audio');

  Future<void> play(FinancialScene scene) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android &&
          await channel.invokeMethod<bool>('canPlay') != true)
        return;
      if (_closed) return;
      await _player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.assistanceSonification,
            audioFocus: AndroidAudioFocus.none,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.ambient,
            options: const {AVAudioSessionOptions.mixWithOthers},
          ),
        ),
      );
      if (_closed) return;
      await _player.setVolume(.24);
      await _player.setReleaseMode(ReleaseMode.stop);
      if (!_closed) {
        await _player.play(AssetSource('audio/financial_${scene.name}.ogg'));
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    _closed = true;
    try {
      await _player.stop();
      await _player.dispose();
    } catch (_) {}
  }
}

class FinancialOperationScene extends StatefulWidget {
  const FinancialOperationScene({
    super.key,
    required this.scene,
    required this.title,
    required this.processingText,
    required this.future,
    required this.onResult,
    required this.onError,
    this.statusText,
    this.duration = const Duration(milliseconds: 2800),
  });
  final FinancialScene scene;
  final String title;
  final String processingText;
  final String? statusText;
  final Future<dynamic> future;
  final void Function(BuildContext, dynamic) onResult;
  final void Function(BuildContext, Object) onError;
  final Duration duration;
  @override
  State<FinancialOperationScene> createState() =>
      _FinancialOperationSceneState();
}

class _FinancialOperationSceneState extends State<FinancialOperationScene>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  FinancialCue? _cue;
  int _generation = 0;
  bool _done = false, _settled = false, _reduced = false;
  dynamic _result;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (_generation == 0) {
      _reduced = reduced;
      _start();
    }
  }

  void _start() {
    final generation = ++_generation;
    _done = false;
    _settled = false;
    _result = null;
    unawaited(_cue?.dispose());
    _cue = FinancialCue();
    _controller.duration = _reduced
        ? const Duration(milliseconds: 250)
        : widget.duration;
    final choreography = _controller.forward(from: 0);
    if (!_reduced) unawaited(_cue!.play(widget.scene));
    unawaited(() async {
      try {
        final result = await widget.future;
        if (!mounted || generation != _generation) return;
        if (result == null)
          throw StateError('The operation returned no result');
        _result = result;
        _done = true;
        setState(() {});
        if (_controller.isAnimating) {
          await choreography.orCancel;
        } else if (_controller.value >= .99) {
          _controller.value = .78;
          await _controller.animateTo(
            1,
            duration: Duration(milliseconds: _reduced ? 80 : 460),
            curve: Curves.easeInOutCubic,
          );
        }
        if (!mounted || generation != _generation || _settled) return;
        _settled = true;
        widget.onResult(context, _result);
      } catch (error) {
        if (!mounted || generation != _generation || _settled) return;
        _settled = true;
        _controller.stop();
        unawaited(_cue?.dispose());
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation)
            widget.onError(context, error);
        });
        setState(() {});
      }
    }());
  }

  @override
  void didUpdateWidget(covariant FinancialOperationScene old) {
    super.didUpdateWidget(old);
    if (old.future != widget.future || old.scene != widget.scene) _start();
  }

  @override
  void dispose() {
    _generation++;
    _controller.dispose();
    unawaited(_cue?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF101013) : AppColors.surfaceLight,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = math.min(constraints.maxHeight * .53, 350.0);
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'FYONA  /  INTELLIGENCE',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10,
                        letterSpacing: 2.3,
                        color: dark
                            ? const Color(0xFFCEA5AD)
                            : AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: height,
                      width: math.min(constraints.maxWidth, 500),
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _controller,
                          builder: (_, __) => CustomPaint(
                            painter: FinancialScenePainter(
                              scene: widget.scene,
                              dark: dark,
                              progress: _reduced
                                  ? .8
                                  : (_done
                                        ? _controller.value
                                        : math.min(.78, _controller.value)),
                              confirmed: _done,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: dark ? Colors.white : const Color(0xFF282429),
                      ),
                    ),
                    const SizedBox(height: 12),
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (_, __) => Text(
                        !_done && _controller.value >= .99
                            ? widget.processingText
                            : widget.statusText ??
                                  (Directionality.of(context) ==
                                          TextDirection.rtl
                                      ? 'تحليل بياناتك الفعلية، بدقة.'
                                      : 'Analysing your actual records, precisely.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11.5,
                          color: dark
                              ? Colors.white60
                              : const Color(0xFF676169),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class FinancialSuccessScene extends StatefulWidget {
  const FinancialSuccessScene({
    super.key,
    this.message,
    this.canvasHeight = 200,
  });
  final String? message;
  final double canvasHeight;
  @override
  State<FinancialSuccessScene> createState() => _FinancialSuccessSceneState();
}

class _FinancialSuccessSceneState extends State<FinancialSuccessScene>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2700),
  );
  final _cue = FinancialCue();
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) _controller.duration = const Duration(milliseconds: 250);
    _controller.forward();
    if (!reduced) unawaited(_cue.play(FinancialScene.balance));
  }

  @override
  void dispose() {
    _controller.dispose();
    unawaited(_cue.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (_, __) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.canvasHeight,
          width: double.infinity,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: FinancialScenePainter(
                scene: FinancialScene.balance,
                progress: _controller.value,
                dark: Theme.of(context).brightness == Brightness.dark,
                confirmed: true,
              ),
            ),
          ),
        ),
        if (widget.message != null)
          Opacity(
            opacity: ((_controller.value - .65) / .35).clamp(0, 1),
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - _controller.value)),
              child: Text(
                widget.message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 18,
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class FinancialScenePainter extends CustomPainter {
  FinancialScenePainter({
    required this.scene,
    required this.progress,
    required this.dark,
    this.confirmed = false,
  });
  final FinancialScene scene;
  final double progress;
  final bool dark, confirmed;
  late Canvas c;
  late double t;
  Color get ink => dark ? const Color(0xFFE4E0E2) : const Color(0xFF29252C);
  Color get silver => dark ? const Color(0xFF77747D) : const Color(0xFFB8B6BE);
  Color get wine => AppColors.primary;
  double phase(double a, double b) =>
      Curves.easeInOutCubic.transform(((t - a) / (b - a)).clamp(0, 1));
  double spring(double value) =>
      value >= 1 ? 1 : 1 - math.exp(-7 * value) * math.cos(9 * value);
  Color alpha(Color v, double a) => v.withValues(alpha: a.clamp(0, 1));
  Paint fill(Color color) => Paint()..color = color;
  Paint stroke(Color color, [double width = 1]) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  Offset iso(double x, double y, double z) =>
      Offset((x - z) * .86, (x + z) * .30 - y);

  void polygon(List<Offset> points, Color color, {bool edge = false}) {
    final p = Path()..moveTo(points.first.dx, points.first.dy);
    for (final v in points.skip(1)) {
      p.lineTo(v.dx, v.dy);
    }
    p.close();
    c.drawPath(p, fill(color));
    if (edge) c.drawPath(p, stroke(alpha(silver, .42), .8));
  }

  void block(
    double x,
    double z,
    double w,
    double d,
    double h, {
    double y = 0,
    Color? color,
  }) {
    final tone = color ?? wine;
    final a = iso(x, y, z),
        b = iso(x + w, y, z),
        q = iso(x + w, y, z + d),
        r = iso(x, y, z + d);
    final lift = Offset(0, -h);
    if (y == 0 && h > 1) {
      final shadow = Path()
        ..moveTo(a.dx + 3, a.dy + 5)
        ..lineTo(b.dx + 3, b.dy + 5)
        ..lineTo(q.dx + 3, q.dy + 5)
        ..lineTo(r.dx + 3, r.dy + 5)
        ..close();
      c.drawPath(
        shadow,
        fill(alpha(Colors.black, dark ? .23 : .11))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    polygon(
      [a, b, b + lift, a + lift],
      Color.lerp(tone, Colors.black, .36)!,
      edge: true,
    );
    polygon(
      [b, q, q + lift, b + lift],
      Color.lerp(tone, Colors.black, .58)!,
      edge: true,
    );
    final top = Path()
      ..moveTo((a + lift).dx, (a + lift).dy)
      ..lineTo((b + lift).dx, (b + lift).dy)
      ..lineTo((q + lift).dx, (q + lift).dy)
      ..lineTo((r + lift).dx, (r + lift).dy)
      ..close();
    c.drawPath(
      top,
      Paint()
        ..shader = ui.Gradient.linear(a + lift, q + lift, [
          Color.lerp(tone, Colors.white, .32)!,
          tone,
        ]),
    );
    c.drawPath(top, stroke(alpha(Colors.white, .24), .8));
    c.drawLine(a + lift, b + lift, stroke(alpha(Colors.white, .47), .8));
  }

  void panel(
    Offset center,
    double w,
    double h, {
    double rotation = 0,
    double opacity = 1,
    int rows = 4,
    bool chart = false,
  }) {
    c.save();
    c.translate(center.dx, center.dy);
    c.rotate(rotation);
    c.transform(
      (Matrix4.identity()
            ..setEntry(3, 2, .0014)
            ..rotateX(-.10)
            ..rotateY(.11 * math.sin(t * math.pi)))
          .storage,
    );
    final rect = Rect.fromCenter(center: Offset.zero, width: w, height: h);
    final shape = RRect.fromRectAndRadius(rect, const Radius.circular(9));
    c.drawRRect(
      shape.shift(const Offset(7, 9)),
      fill(alpha(Colors.black, .16 * opacity))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    c.drawRRect(
      shape.shift(const Offset(4, 5)),
      fill(
        alpha(
          dark ? const Color(0xFF36313B) : const Color(0xFFAAA4AF),
          opacity,
        ),
      ),
    );
    c.drawRRect(
      shape,
      Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
          alpha(dark ? const Color(0xFF41303B) : Colors.white, opacity),
          alpha(
            dark ? const Color(0xFF201D25) : const Color(0xFFE2DEE4),
            opacity,
          ),
        ]),
    );
    c.drawRRect(shape, stroke(alpha(silver, .62 * opacity), .8));
    c.drawLine(
      rect.topLeft + const Offset(12, 14),
      rect.topLeft + Offset(w * .5, 14),
      stroke(alpha(wine, opacity), 3),
    );
    if (chart) {
      for (var i = 0; i < 4; i++) {
        final x = rect.left + 12 + i * (w - 24) / 4;
        final hh = (h - 36) * (.3 + i * .17);
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, rect.bottom - 12 - hh, (w - 30) / 5, hh),
            const Radius.circular(2),
          ),
          fill(alpha(wine, opacity)),
        );
      }
    } else {
      for (var i = 0; i < rows; i++) {
        final yy = rect.top + 30 + i * (h - 40) / math.max(1, rows);
        c.drawLine(
          Offset(rect.left + 12, yy),
          Offset(rect.right - 12, yy),
          stroke(alpha(ink, .20 * opacity), 1.4),
        );
        c.drawLine(
          Offset(rect.right - 24, yy),
          Offset(rect.right - 12, yy),
          stroke(alpha(wine, .7 * opacity), 2),
        );
      }
    }
    c.restore();
  }

  void trace(Offset a, Offset b, double k, {double opacity = 1}) {
    final p = Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(
        a.dx + (b.dx - a.dx) * .45,
        a.dy,
        a.dx + (b.dx - a.dx) * .55,
        b.dy,
        b.dx,
        b.dy,
      );
    c.drawPath(p, stroke(alpha(silver, .25 * opacity), .8));
    final metric = p.computeMetrics().first;
    c.drawPath(
      metric.extractPath(
        math.max(0, k - .16) * metric.length,
        k.clamp(0, 1) * metric.length,
      ),
      stroke(alpha(wine, .9 * opacity), 2),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    c = canvas;
    t = progress.clamp(0, 1);
    c.save();
    c.translate(size.width / 2, size.height * .60);
    final scale = math.min(size.width / 390, size.height / 290);
    c.scale(scale);
    c.translate(3 * math.sin(t * math.pi), -3 * math.sin(t * math.pi));
    final floor = [
      iso(-130, 0, -90),
      iso(125, 0, -90),
      iso(125, 0, 100),
      iso(-130, 0, 100),
    ];
    polygon(floor, alpha(wine, dark ? .055 : .025));
    for (var i = -100; i <= 100; i += 40) {
      c.drawLine(
        iso(i.toDouble(), 0, -90),
        iso(i.toDouble(), 0, 100),
        stroke(alpha(silver, .11), .6),
      );
      c.drawLine(
        iso(-130, 0, i.toDouble()),
        iso(125, 0, i.toDouble()),
        stroke(alpha(silver, .11), .6),
      );
    }
    switch (scene) {
      case FinancialScene.sales:
        _sales();
      case FinancialScene.treasury:
        _treasury();
      case FinancialScene.inventory:
        _inventory();
      case FinancialScene.debts:
        _debts();
      case FinancialScene.executive:
        _executive();
      case FinancialScene.precision:
        _precision();
      case FinancialScene.balance:
        _balance();
    }
    c.restore();
  }

  void _sales() {
    final enter = spring(phase(0, .28));
    final morph = phase(.34, .72);
    for (final sign in [-1.0, 1.0]) {
      final center = Offset(
        sign * (175 - 110 * enter) * (1 - morph),
        -80 + 25 * morph,
      );
      panel(
        center,
        86 * (1 - morph) + 20 * morph,
        112 * (1 - morph) + 60 * morph,
        rotation: sign * .16 * (1 - morph),
        opacity: 1 - phase(.57, .76),
        rows: 4,
      );
      trace(
        Offset(sign * 130, -50),
        Offset(sign * 20, -25),
        phase(.15, .6),
        opacity: 1 - morph,
      );
    }
    for (var i = 0; i < 6; i++) {
      final k = phase(.38 + i * .035, .68 + i * .025);
      block(
        -94 + i * 29,
        -15,
        17,
        24,
        (30 + (i % 3) * 26 + i * 4) * k,
        color: i.isEven
            ? wine
            : dark
            ? const Color(0xFF77717C)
            : const Color(0xFFBBB4C0),
      );
    }
    _finalReport(phase(.79, 1), 0);
  }

  void _treasury() {
    final enter = phase(0, .3);
    panel(
      Offset(-125 + 18 * enter, -68),
      70,
      91,
      rotation: -.11,
      opacity: 1 - phase(.72, .9),
    );
    panel(
      Offset(128 - 18 * enter, -26),
      70,
      91,
      rotation: .11,
      opacity: 1 - phase(.72, .9),
    );
    block(
      -24,
      -23,
      47,
      47,
      72 * spring(phase(.1, .4)),
      color: dark ? const Color(0xFF51434E) : const Color(0xFFAAA2AE),
    );
    final core = phase(.16, .45);
    final circuit = Path()
      ..moveTo(iso(-16, 20, -23).dx, iso(-16, 20, -23).dy)
      ..lineTo(iso(15, 20, -23).dx, iso(15, 20, -23).dy)
      ..lineTo(iso(15, 55 * core, -23).dx, iso(15, 55 * core, -23).dy)
      ..lineTo(iso(-16, 55 * core, -23).dx, iso(-16, 55 * core, -23).dy)
      ..close();
    c.drawPath(circuit, stroke(alpha(wine, core), 1.5));
    for (var i = 0; i < 3; i++) {
      c.drawLine(
        iso(-10, 29 + i * 7.0, -23),
        iso(9, 29 + i * 7.0, -23),
        stroke(alpha(Colors.white, .42 * core), 1),
      );
    }
    for (var i = 0; i < 4; i++) {
      final y = -95 + i * 22.0;
      trace(
        Offset(-95, y),
        Offset(-5, -75 + i * 12),
        phase(.2 + i * .05, .65 + i * .035),
      );
      trace(
        Offset(12, -66 + i * 10),
        Offset(92, y + 34),
        phase(.33 + i * .04, .8 + i * .025),
      );
    }
    final k = phase(.57, .84);
    for (var i = 0; i < 3; i++) {
      final y = 18 + i * 14.0;
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-75, y, 150 * k, 5),
          const Radius.circular(2),
        ),
        fill(i == 1 ? alpha(silver, .7) : wine),
      );
    }
    _finalReport(phase(.82, 1), 1);
  }

  void _inventory() {
    final morph = phase(.6, .91);
    for (var shelf = 0; shelf < 3; shelf++) {
      final z = -50 + shelf * 40.0;
      for (final x in [-110.0, 88.0])
        block(x, z, 5, 5, 120 * (1 - morph), color: silver);
      for (var level = 0; level < 2; level++) {
        final y = 18 + level * 53.0;
        block(
          -110,
          z,
          203,
          8,
          4,
          y: y * (1 - morph),
          color: dark ? const Color(0xFF5F5964) : const Color(0xFFC2BDC5),
        );
        for (var j = 0; j < 3; j++) {
          final delay = (shelf * 3 + j) * .028;
          final k = phase(delay, .29 + delay);
          final rise = math.max(0, 1 - spring(k)) * 45;
          block(
            -91 + j * 58.0,
            z - 17,
            30,
            23,
            (29 + 11 * (j % 2)) * (1 + morph * .6),
            y: y * (1 - morph) + rise,
            color: j == 1
                ? wine
                : dark
                ? const Color(0xFF645C69)
                : const Color(0xFFB5AEBB),
          );
        }
      }
    }
    final scan = phase(.35, .68);
    if (scan > 0 && scan < 1) {
      final z = -75 + 160 * scan;
      polygon([
        iso(-118, 8, z),
        iso(110, 8, z),
        iso(110, 142, z),
        iso(-118, 142, z),
      ], alpha(wine, .075));
      c.drawLine(
        iso(-118, 142, z),
        iso(110, 142, z),
        stroke(alpha(wine, .8), 1.5),
      );
    }
    _finalReport(phase(.86, 1), 2);
  }

  void _debts() {
    final move = phase(0, .38);
    final morph = phase(.34, .75);
    for (final sign in [-1.0, 1.0]) {
      panel(
        Offset(sign * (160 - 65 * move), -70),
        72,
        105,
        rotation: sign * .07 * (1 - morph),
        opacity: 1 - morph,
        rows: 5,
      );
      trace(
        Offset(sign * 76, -52),
        Offset(sign * 32, -38),
        phase(.2, .65),
        opacity: 1 - phase(.8, 1),
      );
    }
    c.save();
    c.translate(0, -76);
    c.rotate(math.sin(t * 8) * .1 * (1 - phase(.55, .85)));
    final show = morph;
    c.drawLine(
      Offset(-100 * show, 0),
      Offset(100 * show, 0),
      stroke(silver, 5),
    );
    for (final sign in [-1.0, 1.0]) {
      c.drawLine(
        Offset(sign * 88, 0),
        Offset(sign * 88, 55),
        stroke(alpha(ink, show), 1.3),
      );
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(sign * 88, 59),
            width: 65 * show,
            height: 8,
          ),
          const Radius.circular(3),
        ),
        fill(wine),
      );
    }
    c.restore();
    block(
      -5,
      -4,
      10,
      10,
      100 * morph,
      color: dark ? const Color(0xFF817784) : silver,
    );
    block(-35, -25, 65, 45, 8 * morph, color: wine);
    _finalReport(phase(.8, 1), 3);
  }

  void _executive() {
    final settle = phase(.35, .78);
    panel(
      const Offset(0, -58),
      260 * settle,
      170 * settle,
      opacity: settle,
      rows: 0,
    );
    final starts = [
      const Offset(-135, -133),
      const Offset(130, -128),
      const Offset(-128, 24),
      const Offset(127, 32),
    ];
    final ends = [
      const Offset(-65, -91),
      const Offset(65, -91),
      const Offset(-65, -19),
      const Offset(65, -19),
    ];
    for (var i = 0; i < 4; i++) {
      final arrive = phase(i * .035, .29 + i * .035);
      final center =
          Offset.lerp(starts[i], ends[i], settle)! +
          Offset(0, (1 - arrive) * 30 + math.sin(t * 5 + i) * 5 * (1 - settle));
      trace(
        starts[i],
        Offset.zero,
        phase(.16 + i * .05, .64 + i * .04),
        opacity: 1 - settle,
      );
      panel(
        center,
        85 + 10 * settle,
        62,
        opacity: arrive,
        rows: i.isEven ? 2 : 3,
        chart: i.isEven,
      );
      if (i == 2 && settle < .65) {
        c.save();
        c.translate(center.dx, center.dy + 8);
        block(-12, -8, 17, 15, 20 * arrive, color: wine);
        c.restore();
      }
    }
    final sweep = phase(.69, .88);
    if (sweep > 0 && sweep < 1) {
      final x = -125 + 250 * sweep;
      c.drawLine(
        Offset(x, -139),
        Offset(x + 18, 28),
        stroke(alpha(Colors.white, .4), 2),
      );
    }
    _finalReport(phase(.86, 1), 4);
  }

  void _precision() {
    final approach = phase(0, .3);
    for (final sign in [-1.0, 1.0]) {
      panel(
        Offset(sign * (175 - 86 * approach), -65),
        108,
        148,
        rotation: sign * .05 * (1 - approach),
        rows: 6,
      );
    }
    final scan = phase(.24, .76);
    final y = -115 + 110 * scan;
    c.drawLine(Offset(-141, y), Offset(141, y), stroke(alpha(wine, .65), 1.5));
    for (var row = 0; row < 6; row++) {
      final at = phase(.27 + row * .065, .39 + row * .065);
      final yy = -109 + row * 19.0;
      trace(Offset(-36, yy), Offset(36, yy), at, opacity: .7);
      if (at > 0) {
        polygon([
          Offset(-4, yy - 4),
          Offset(4, yy - 4),
          Offset(4, yy + 4),
          Offset(-4, yy + 4),
        ], alpha(wine, .3 + at * .5));
      }
    }
    final mesh = phase(.65, .95);
    for (var i = 0; i < 4; i++) {
      c.drawLine(
        Offset(-25 + i * 16.0, 12),
        Offset(-25 + i * 16.0, 12 + 28 * mesh),
        stroke(alpha(silver, mesh), 1),
      );
      c.drawLine(
        Offset(-25, 12 + i * 8.0),
        Offset(-25 + 50 * mesh, 12 + i * 8.0),
        stroke(alpha(wine, mesh), 1),
      );
    }
  }

  void _balance() {
    final join = phase(0, .57);
    final seal = phase(.44, .76);
    final check = phase(.72, 1);
    for (final sign in [-1.0, 1.0]) {
      c.save();
      c.translate(sign * (145 * (1 - join)), -55 + sign * 22 * (1 - join));
      block(-58, -9, 116, 17, 8, color: sign < 0 ? wine : silver);
      for (var j = 0; j < 3; j++) {
        c.drawLine(
          Offset(-40 + j * 30.0, -30),
          Offset(-40 + j * 30.0, -24),
          stroke(alpha(silver, 1 - seal), 1),
        );
      }
      c.restore();
    }
    final radius = 68 * seal;
    final points = [
      for (var i = 0; i < 6; i++)
        Offset(
          math.cos(i * math.pi / 3) * radius,
          -52 + math.sin(i * math.pi / 3) * radius,
        ),
    ];
    if (seal > 0) {
      polygon(
        points.map((v) => v + const Offset(6, 8)).toList(),
        alpha(Colors.black, .4),
      );
      polygon(points, Color.lerp(wine, Colors.black, .2)!, edge: true);
      c.drawLine(
        Offset(-30, -65),
        Offset(30, -65),
        stroke(alpha(Colors.white, 1 - check), 4),
      );
      c.drawLine(
        Offset(-30, -42),
        Offset(30, -42),
        stroke(alpha(Colors.white, 1 - check), 4),
      );
      final start = [
        const Offset(-30, -53),
        const Offset(0, -53),
        const Offset(30, -53),
      ];
      final end = [
        const Offset(-26, -53),
        const Offset(-6, -32),
        const Offset(30, -73),
      ];
      final p = Path();
      for (var i = 0; i < 3; i++) {
        final v = Offset.lerp(start[i], end[i], check)!;
        if (i == 0) {
          p.moveTo(v.dx, v.dy);
        } else {
          p.lineTo(v.dx, v.dy);
        }
      }
      c.drawPath(p, stroke(alpha(Colors.white, check), 5));
    }
  }

  void _finalReport(double k, int glyph) {
    if (k <= 0) return;
    c.save();
    c.translate(0, -55);
    c.scale(.58 + .42 * spring(k));
    final rect = Rect.fromCenter(center: Offset.zero, width: 104, height: 124);
    c.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(11)),
      fill(alpha(dark ? const Color(0xFF242028) : Colors.white, k)),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(11)),
      stroke(alpha(wine, k), 2),
    );
    c.drawLine(
      const Offset(-29, -40),
      const Offset(16, -40),
      stroke(alpha(silver, k), 3),
    );
    if (glyph == 4) {
      for (var i = 0; i < 4; i++) {
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(-29 + (i % 2) * 34.0, -20 + (i ~/ 2) * 31.0, 25, 23),
            const Radius.circular(3),
          ),
          fill(alpha(wine, k)),
        );
      }
    } else if (glyph == 1) {
      for (var i = 0; i < 3; i++) {
        c.drawLine(
          Offset(-28, -12 + i * 17.0),
          Offset(28, -12 + i * 17.0),
          stroke(alpha(wine, k), 4),
        );
      }
    } else {
      for (var i = 0; i < 3; i++) {
        final height = [27.0, 43.0, 35.0][(i + glyph) % 3];
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(-28 + i * 21.0, 31 - height, 12, height),
            const Radius.circular(2),
          ),
          fill(alpha(wine, k)),
        );
      }
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant FinancialScenePainter old) =>
      old.scene != scene ||
      old.progress != progress ||
      old.dark != dark ||
      old.confirmed != confirmed;
}
