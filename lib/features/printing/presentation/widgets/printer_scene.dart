import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// What the printer drawing shows.
enum SceneState { idle, scanning, connecting, printing, waiting, printed, sent, failed }

/// The Print Center's printer, with the receipt coming out of it.
///
/// The paper rises from the slot: its first printed lines (the invoice
/// header) come out first and climb, the rest follows — the visible length
/// is [progress] (0..1), which the page drives from the REAL job progress
/// (bytes delivered, or the printer's own job state). It reaches the end
/// only when the job is done, and the "printed" check appears only when the
/// printer confirmed it ([SceneState.printed]); a printer that cannot
/// confirm shows [SceneState.sent] instead — never a false success.
class PrinterScene extends StatefulWidget {
  const PrinterScene({
    super.key,
    required this.state,
    required this.progress,
    required this.paper,
    this.paperWidth = 150,
    this.maxPaper = 200,
  });

  final SceneState state;
  final double progress;

  /// What is printed (the real invoice preview), drawn on the paper.
  final Widget paper;
  final double paperWidth;
  final double maxPaper;

  @override
  State<PrinterScene> createState() => _PrinterSceneState();
}

class _PrinterSceneState extends State<PrinterScene> with TickerProviderStateMixin {
  // Smooth follower of the real progress (never jumps, never runs ahead).
  late final AnimationController _shown =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  // LED pulse / head vibration / scan sweep.
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  // Success / failure accent.
  late final AnimationController _finish =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650));

  @override
  void initState() {
    super.initState();
    _shown.value = widget.progress.clamp(0, 1);
  }

  @override
  void didUpdateWidget(covariant PrinterScene old) {
    super.didUpdateWidget(old);
    final target = widget.progress.clamp(0.0, 1.0);
    if (target != _shown.value) {
      _shown.animateTo(target,
          duration: Duration(milliseconds: target < _shown.value ? 300 : 420),
          curve: Curves.easeOutCubic);
    }
    final end = {SceneState.printed, SceneState.sent, SceneState.failed};
    if (end.contains(widget.state) && !end.contains(old.state)) {
      _finish.forward(from: 0);
    } else if (!end.contains(widget.state)) {
      _finish.value = 0;
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    _pulse.dispose();
    _finish.dispose();
    super.dispose();
  }

  Color get _led => switch (widget.state) {
        SceneState.printed => AppColors.success,
        SceneState.sent => AppColors.info,
        SceneState.failed => AppColors.danger,
        SceneState.idle => AppColors.textDisabled,
        _ => AppColors.warning,
      };

  bool get _active => widget.state == SceneState.connecting ||
      widget.state == SceneState.printing ||
      widget.state == SceneState.waiting ||
      widget.state == SceneState.scanning;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    const bodyH = 104.0;
    final total = widget.maxPaper + bodyH + 24;
    return Semantics(
      label: 'printer',
      child: SizedBox(
        height: total,
        child: AnimatedBuilder(
          animation: Listenable.merge([_shown, _pulse, _finish]),
          builder: (context, _) {
            final p = _shown.value;
            final pulse = reduce ? .5 : (math.sin(_pulse.value * 2 * math.pi) + 1) / 2;
            final printing = widget.state == SceneState.printing && !reduce;
            // A light shake of the head while it prints; a short shake on error.
            final shake = printing
                ? math.sin(_pulse.value * 2 * math.pi * 6) * .6
                : widget.state == SceneState.failed && !reduce
                    ? math.sin(_finish.value * math.pi * 8) * 5 * (1 - _finish.value)
                    : 0.0;
            final paperH = widget.maxPaper * p;
            // Printed: the receipt is torn off and lifts slightly.
            final lift = widget.state == SceneState.printed && !reduce
                ? Curves.easeOut.transform(_finish.value) * 10
                : 0.0;
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                // Soft glow in the brand colour (pulses while working).
                Positioned(
                  bottom: 0,
                  child: Container(
                    width: 240,
                    height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [
                        (widget.state == SceneState.failed ? AppColors.danger : AppColors.primary)
                            .withAlpha((_active ? 40 + 50 * pulse : 34).round()),
                        AppColors.primary.withAlpha(0),
                      ]),
                    ),
                  ),
                ),
                // The receipt.
                Positioned(
                  bottom: bodyH - 14 + lift,
                  child: Opacity(
                    opacity: paperH < 1 ? 0 : 1,
                    child: ClipRect(
                      child: SizedBox(
                        width: widget.paperWidth,
                        height: paperH,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(dark ? 120 : 38),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minHeight: widget.maxPaper,
                            maxHeight: widget.maxPaper,
                            child: Stack(children: [
                              Positioned.fill(child: IgnorePointer(child: widget.paper)),
                              // Torn edge at the top once it is cut.
                              if (widget.state == SceneState.printed)
                                const Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: _TornEdge(),
                                ),
                              // Fresh ink: a faint sheen near the slot.
                              if (printing)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: math.max(0, paperH - 18),
                                  height: 18,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.white.withAlpha(0),
                                          AppColors.primary.withAlpha(20),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Printer body.
                Positioned(
                  bottom: 12,
                  child: Transform.translate(
                    offset: Offset(shake, 0),
                    child: _PrinterBody(
                      height: bodyH,
                      led: _led,
                      ledGlow: _active ? pulse : 1,
                      dark: dark,
                      slotWidth: widget.paperWidth + 16,
                    ),
                  ),
                ),
                // Outcome badge.
                if (widget.state == SceneState.printed ||
                    widget.state == SceneState.sent ||
                    widget.state == SceneState.failed)
                  Positioned(
                    bottom: 12 + bodyH - 22,
                    right: 0,
                    left: 0,
                    child: Center(
                      child: Transform.translate(
                        offset: const Offset(92, 0),
                        child: Transform.scale(
                          scale: Curves.elasticOut.transform(_finish.value.clamp(0, 1)),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: _led,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: _led.withAlpha(110), blurRadius: 14),
                              ],
                            ),
                            child: Icon(
                              widget.state == SceneState.printed
                                  ? Icons.check_rounded
                                  : widget.state == SceneState.sent
                                      ? Icons.send_rounded
                                      : Icons.priority_high_rounded,
                              color: Colors.white,
                              size: 20,
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
      ),
    );
  }
}

class _PrinterBody extends StatelessWidget {
  const _PrinterBody({
    required this.height,
    required this.led,
    required this.ledGlow,
    required this.dark,
    required this.slotWidth,
  });

  final double height;
  final Color led;
  final double ledGlow;
  final bool dark;
  final double slotWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.surface, AppColors.surfaceVariant],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.primary.withAlpha(80)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(dark ? 110 : 34),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(alignment: Alignment.topCenter, children: [
        // Paper slot.
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: slotWidth,
          height: 9,
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(dark ? 180 : 70),
            borderRadius: BorderRadius.circular(5),
          ),
        ),
        // Front panel: brand stripe, LED, button.
        Positioned(
          bottom: 14,
          left: 18,
          right: 18,
          child: Row(children: [
            Container(
              width: 44,
              height: 6,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const Spacer(),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: led,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: led.withAlpha((90 + 120 * ledGlow).round()), blurRadius: 8 + 6 * ledGlow),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(Icons.power_settings_new_rounded,
                  size: 12, color: AppColors.textSecondary),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _TornEdge extends StatelessWidget {
  const _TornEdge();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(double.infinity, 6), painter: _TornPainter());
}

class _TornPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(0, 0);
    const step = 6.0;
    for (var x = 0.0; x <= size.width; x += step) {
      path.lineTo(x + step / 2, size.height);
      path.lineTo(x + step, 0);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = AppColors.background);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
