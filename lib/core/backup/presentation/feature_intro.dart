import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../localization/app_localizations.dart';
import '../../theme/app_colors.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';

/// One scene of an explainer: icons that come in, one after the other,
/// joined by a moving arrow, and a caption.
class IntroScene {
  const IntroScene(this.icons, this.caption, {this.saraAt});
  final List<IconData> icons;
  final String caption;

  /// Which icon is Sara (her own picture is shown there).
  final int? saraAt;
}

/// A short explainer that plays like a video: scenes advance by themselves
/// with a progress bar per scene; pause, replay, or tap to skip.
class IntroPlayer extends StatefulWidget {
  const IntroPlayer({super.key, required this.scenes, required this.colors, this.sceneTime = const Duration(milliseconds: 3200)});
  final List<IntroScene> scenes;
  final List<Color> colors;
  final Duration sceneTime;
  @override
  State<IntroPlayer> createState() => _IntroPlayerState();
}

class _IntroPlayerState extends State<IntroPlayer> with TickerProviderStateMixin {
  late final _scene = AnimationController(vsync: this, duration: widget.sceneTime);
  late final _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  int _i = 0;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _scene.addStatusListener((s) {
      if (s != AnimationStatus.completed || !mounted) return;
      if (_i < widget.scenes.length - 1) {
        setState(() => _i++);
        _scene.forward(from: 0);
      } else {
        setState(() => _paused = true);
      }
    });
    _scene.forward();
  }

  @override
  void dispose() {
    _scene.dispose();
    _loop.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      if (_paused) {
        if (_i == widget.scenes.length - 1 && _scene.isCompleted) {
          _i = 0;
          _scene.forward(from: 0);
        } else {
          _scene.forward();
        }
        _paused = false;
      } else {
        _scene.stop();
        _paused = true;
      }
    });
  }

  void _skip() {
    if (_i < widget.scenes.length - 1) {
      setState(() => _i++);
      _scene.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scenes[_i];
    return GestureDetector(
      key: const Key('intro-player'),
      onTap: _skip,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(colors: widget.colors, begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd),
            boxShadow: [BoxShadow(color: widget.colors.first.withValues(alpha: .18), blurRadius: 14, offset: const Offset(0, 6))],
          ),
          child: Stack(children: [
            // Scene bars.
            Positioned(
              top: 10,
              left: 12,
              right: 12,
              child: AnimatedBuilder(
                animation: _scene,
                builder: (_, _) => Row(children: [
                  for (var k = 0; k < widget.scenes.length; k++) ...[
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          value: k < _i ? 1 : k == _i ? _scene.value : 0,
                          backgroundColor: Colors.white24,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (k < widget.scenes.length - 1) const SizedBox(width: 4),
                  ],
                ]),
              ),
            ),
            Positioned.fill(
              top: 22,
              bottom: 44,
              child: AnimatedBuilder(
                animation: Listenable.merge([_scene, _loop]),
                builder: (_, _) {
                  final n = scene.icons.length;
                  return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (var k = 0; k < n; k++) ...[
                      _pop(k / (n + 1), scene.icons[k], big: k == n - 1, sara: scene.saraAt == k),
                      if (k < n - 1) _arrow(k / (n + 1)),
                    ],
                  ]);
                },
              ),
            ),
            PositionedDirectional(
              start: 14,
              end: 56,
              bottom: 12,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(scene.caption,
                    key: ValueKey(_i),
                    maxLines: 2,
                    style: const TextStyle(fontFamily: _font, fontSize: 14.5, fontWeight: FontWeight.w800, color: Colors.white, height: 1.4)),
              ),
            ),
            PositionedDirectional(
              end: 8,
              bottom: 6,
              child: IconButton(
                key: const Key('intro-play'),
                onPressed: _toggle,
                icon: Icon(
                    _paused
                        ? (_i == widget.scenes.length - 1 && _scene.isCompleted ? Icons.replay_rounded : Icons.play_arrow_rounded)
                        : Icons.pause_rounded,
                    color: Colors.white),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// An icon that pops in at [at] of the scene.
  Widget _pop(double at, IconData icon, {bool big = false, bool sara = false}) {
    final v = ((_scene.value - at) / .18).clamp(0.0, 1.0);
    final e = Curves.easeOutBack.transform(v);
    final float = math.sin(_loop.value * 2 * math.pi + at * 6) * 3;
    return Opacity(
      opacity: v,
      child: Transform.translate(
        offset: Offset(0, (1 - e) * 18 + float),
        child: Transform.scale(
          scale: .6 + .4 * e,
          child: Container(
            width: big ? 74 : 58,
            height: big ? 74 : 58,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: big ? .95 : .18),
              shape: BoxShape.circle,
              boxShadow: big ? [BoxShadow(color: Colors.white.withValues(alpha: .35), blurRadius: 18)] : null,
            ),
            padding: EdgeInsets.all(sara ? 3 : 0),
            child: sara
                ? ClipOval(child: Image.asset('assets/images/sara_avatar.jpg', fit: BoxFit.cover, cacheWidth: 220))
                : Icon(icon, color: big ? widget.colors.first : Colors.white, size: big ? 36 : 28),
          ),
        ),
      ),
    );
  }

  Widget _arrow(double at) {
    final v = ((_scene.value - at - .1) / .15).clamp(0.0, 1.0);
    return Opacity(
      opacity: v,
      child: SizedBox(
        width: 34,
        child: Transform.translate(
          offset: Offset((_loop.value - .5) * 8 * (Directionality.of(context) == TextDirection.rtl ? -1 : 1), 0),
          // Mirrored by Flutter in Arabic: the flow reads right → left there
          // and left → right in English.
          child: const Icon(Icons.arrow_forward_rounded, color: Colors.white70),
        ),
      ),
    );
  }
}

/// The sheet a feature button opens: its explainer, a few tidy points and
/// the start button.
Future<void> showFeatureIntro(
  BuildContext context, {
  required String title,
  required IconData icon,
  required List<Color> colors,
  required List<IntroScene> scenes,
  required List<(IconData, String)> points,
  required String start,
  required VoidCallback onStart,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .9),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(width: 42, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(13)),
                  child: Icon(icon, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: const TextStyle(fontFamily: _font, fontSize: 18, fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 14),
              IntroPlayer(scenes: scenes, colors: colors),
              const SizedBox(height: 16),
              for (final p in points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(color: colors.first.withValues(alpha: .10), borderRadius: BorderRadius.circular(9)),
                      child: Icon(p.$1, size: 17, color: colors.first),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(p.$2, style: const TextStyle(fontFamily: _font, fontSize: 13.5, height: 1.5)),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: 6),
              SizedBox(
                height: 54,
                child: DecoratedBox(
                  decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(16)),
                  child: FilledButton.icon(
                    key: const Key('intro-start'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      onStart();
                    },
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(start, style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(_t('introTapToSkip'), style: TextStyle(fontFamily: _font, fontSize: 11, color: AppColors.textSecondary)),
              ),
            ]),
          ),
        ),
      ),
    );

/// A big colored button with an icon and a title only.
class FeatureButton extends StatelessWidget {
  const FeatureButton({super.key, required this.title, required this.icon, required this.colors, this.onTap});
  final String title;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? .5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors, begin: Alignment.topRight, end: Alignment.bottomLeft),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: colors.first.withValues(alpha: .28), blurRadius: 14, offset: const Offset(0, 6))],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: onTap,
              child: SizedBox(
                height: 104,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .2), shape: BoxShape.circle),
                    child: Icon(icon, color: Colors.white, size: 25),
                  ),
                  const SizedBox(height: 8),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontFamily: _font, fontSize: 14.5, fontWeight: FontWeight.w800, color: Colors.white)),
                ]),
              ),
            ),
          ),
        ),
      );
}
