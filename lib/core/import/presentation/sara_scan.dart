import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../backup/presentation/operation_motion.dart';
import '../../localization/app_localizations.dart';
import 'smart_import_page.dart' show SaraAvatar;

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';
const _brand = Color(0xFF9E1B32);
const _deep = Color(0xFF2A0710);

/// «تحليل سارة»: the file's tables drop out of her button onto the screen
/// and a scanning beam passes over them, top to bottom, while she reads
/// them (with a soft scan sound); a check closes it when she is done.
///
/// [work] is Sara's real call; its result is returned unchanged. [ok]
/// tells whether it succeeded (a failure shows a short "could not reach
/// Sara" state instead of the check). [motion] false: no overlay (tests).
class SaraScan {
  static Future<T> run<T>(
    BuildContext context, {
    required List<String> tables,
    required Future<T> Function() work,
    required bool Function(T result) ok,
    bool motion = true,
  }) async {
    if (!motion) return work();
    final done = Completer<T>();
    final state = ValueNotifier<int>(0); // 0 working · 1 done · -1 failed
    unawaited(work().then((r) {
      if (!done.isCompleted) done.complete(r);
      state.value = ok(r) ? 1 : -1;
    }, onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
      state.value = -1;
    }));
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => _SaraScanView(tables: tables, state: state),
    );
    state.dispose();
    return done.future;
  }
}

class _SaraScanView extends StatefulWidget {
  const _SaraScanView({required this.tables, required this.state});
  final List<String> tables;
  final ValueNotifier<int> state;
  @override
  State<_SaraScanView> createState() => _SaraScanViewState();
}

class _SaraScanViewState extends State<_SaraScanView> with TickerProviderStateMixin {
  late final _drop = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..forward();
  late final _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  late final _finish = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  final _started = DateTime.now();
  int _passes = 0;

  @override
  void initState() {
    super.initState();
    HapticFeedback.lightImpact();
    unawaited(playMotionSound('audio/recon_scan.mp3', volume: .5));
    _drop.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) _sweep.forward(from: 0);
    });
    _sweep.addStatusListener((s) {
      if (s != AnimationStatus.completed || !mounted) return;
      _passes++;
      // Sara still reading: another pass (the beam always finishes one
      // full pass, so even a quick answer is seen being scanned).
      if (widget.state.value == 0 || _passes < 1) {
        if (_passes.isEven) unawaited(playMotionSound('audio/recon_scan.mp3', volume: .4));
        _sweep.forward(from: 0);
      } else {
        _end();
      }
    });
    widget.state.addListener(_onState);
  }

  void _onState() {
    if (widget.state.value != 0 && !_sweep.isAnimating && _drop.isCompleted) _end();
  }

  bool _ending = false;
  Future<void> _end() async {
    if (_ending) return;
    _ending = true;
    final good = widget.state.value == 1;
    unawaited(playMotionSound(good ? 'audio/sara_success.wav' : 'audio/sara_error.wav', volume: .7));
    if (good) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
    await _finish.forward();
    // At least a moment on screen, then the arranged data opens.
    final shown = DateTime.now().difference(_started);
    await Future<void>.delayed(Duration(milliseconds: math.max(good ? 650 : 1300, 1600 - shown.inMilliseconds)));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _drop.dispose();
    _sweep.dispose();
    _finish.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.tables.take(7).toList();
    final more = widget.tables.length - rows.length;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return PopScope(
      canPop: false,
      child: AnimatedBuilder(
        animation: Listenable.merge([_drop, _sweep, _finish]),
        builder: (context, _) {
          final d = Curves.easeOutBack.transform(_drop.value.clamp(0, 1));
          final f = Curves.easeOut.transform(_finish.value);
          final failed = widget.state.value == -1;
          // From Sara's button (top, on the end side) down to the middle.
          final from = Alignment(rtl ? -.82 : .82, -.93);
          return Material(
            color: _deep.withValues(alpha: .88 * _drop.value.clamp(0, 1)),
            child: SafeArea(
              child: Align(
                alignment: Alignment.lerp(from, const Alignment(0, -.1), d)!,
                child: Transform.scale(
                  scale: .25 + .75 * d,
                  child: Opacity(
                    opacity: _drop.value.clamp(0, 1),
                    child: Container(
                      width: 310,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: const LinearGradient(
                            begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF5A0F1F), _deep]),
                        border: Border.all(color: Colors.white.withValues(alpha: .14)),
                        boxShadow: [BoxShadow(color: _brand.withValues(alpha: .45), blurRadius: 40, spreadRadius: 2)],
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Row(children: [
                          const SaraAvatar(size: 38, ring: true),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_t('si4SaraScanTitle'),
                                  style: const TextStyle(
                                      fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white)),
                              Text(
                                  failed
                                      ? _t('si3SaraOff')
                                      : f > 0
                                          ? _t('si4SaraScanDone')
                                          : _t('si4SaraScanSub', {'n': '${widget.tables.length}'}),
                                  maxLines: 2,
                                  style: TextStyle(
                                      fontFamily: _font,
                                      fontSize: 11.5,
                                      height: 1.4,
                                      color: failed ? const Color(0xFFFFC107) : Colors.white70)),
                            ]),
                          ),
                        ]),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 28.0 * rows.length + (more > 0 ? 22 : 0),
                          child: Stack(clipBehavior: Clip.none, children: [
                            Column(children: [
                              for (var i = 0; i < rows.length; i++)
                                _Row(
                                  name: rows[i],
                                  scanned: _passes > 0 || _sweep.value * rows.length > i + .5,
                                  delay: i,
                                  drop: _drop.value,
                                ),
                              if (more > 0)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(_t('si4SaraScanMore', {'n': '$more'}),
                                      style: const TextStyle(fontFamily: _font, fontSize: 11, color: Colors.white54)),
                                ),
                            ]),
                            // The beam: a bright line with a soft trail above it.
                            if (_drop.isCompleted && f < 1)
                              Positioned(
                                left: -6,
                                right: -6,
                                top: _sweep.value * (28.0 * rows.length) - 26,
                                child: Opacity(
                                  opacity: 1 - f,
                                  child: Column(children: [
                                    Container(
                                      height: 26,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [const Color(0x00FF5A6E), const Color(0xFFFF5A6E).withValues(alpha: .28)],
                                        ),
                                      ),
                                    ),
                                    Container(
                                      height: 2.4,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(2),
                                        boxShadow: const [
                                          BoxShadow(color: Color(0xFFFF4D63), blurRadius: 14, spreadRadius: 2),
                                          BoxShadow(color: Colors.white, blurRadius: 4),
                                        ],
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            // Done: a check in the middle.
                            if (f > 0)
                              Center(
                                child: Transform.scale(
                                  scale: Curves.elasticOut.transform(_finish.value),
                                  child: Container(
                                    width: 74,
                                    height: 74,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: failed ? const Color(0xFFB7791F) : const Color(0xFF2E7D32),
                                      boxShadow: [
                                        BoxShadow(
                                            color: (failed ? const Color(0xFFB7791F) : const Color(0xFF2E7D32))
                                                .withValues(alpha: .5),
                                            blurRadius: 24),
                                      ],
                                    ),
                                    child: Icon(failed ? Icons.wifi_off_rounded : Icons.check_rounded,
                                        color: Colors.white, size: 44),
                                  ),
                                ),
                              ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.name, required this.scanned, required this.delay, required this.drop});
  final String name;
  final bool scanned;
  final int delay;
  final double drop;
  @override
  Widget build(BuildContext context) {
    final t = ((drop - delay * .06) / .6).clamp(0.0, 1.0);
    return Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, (1 - t) * -12),
        child: SizedBox(
          height: 28,
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scanned ? Colors.white : Colors.white.withValues(alpha: .10),
              ),
              child: Icon(scanned ? Icons.check_rounded : Icons.table_rows_rounded,
                  size: 13, color: scanned ? _brand : Colors.white54),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.start,
                  style: TextStyle(
                      fontFamily: _font,
                      fontSize: 12.5,
                      fontWeight: scanned ? FontWeight.w800 : FontWeight.w600,
                      color: scanned ? Colors.white : Colors.white60)),
            ),
            const SizedBox(width: 8),
            for (var i = 0; i < 3; i++)
              Container(
                width: 14.0 + (name.length * (i + 3)) % 18,
                height: 5,
                margin: const EdgeInsetsDirectional.only(start: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: scanned ? .45 : .14),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
