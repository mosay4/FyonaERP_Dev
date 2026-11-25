import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';

/// Calm branded entry screen shown while the app prepares (session restore,
/// biometric step, account entry). Replaces the plain loading spinner.
///
/// The logo reveals ONCE per app session with a short fade/scale and a soft
/// burgundy glow, then stays still — no infinite animation (pumpAndSettle
/// friendly). Every instance shares the reveal progress, so the splash and
/// the account-entry step look like one continuous screen: a later instance
/// resumes the reveal where the previous one was instead of restarting it.
class BrandEntryView extends StatefulWidget {
  const BrandEntryView({super.key, this.footer});

  /// Optional widget under the logo (e.g. a retry button).
  final Widget? footer;

  /// Always-dark brand background (matches the native black launch screen
  /// fading into the app's graphite).
  static const Color background = Color(0xFF0E0F12);
  static const Duration revealDuration = Duration(milliseconds: 900);

  static double _revealProgress = 0;

  /// Forgets the shared reveal progress (tests).
  @visibleForTesting
  static void resetReveal() => _revealProgress = 0;

  @override
  State<BrandEntryView> createState() => _BrandEntryViewState();
}

class _BrandEntryViewState extends State<BrandEntryView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(
      vsync: this,
      duration: BrandEntryView.revealDuration,
      value: BrandEntryView._revealProgress,
    )..addListener(() {
        if (_reveal.value > BrandEntryView._revealProgress) {
          BrandEntryView._revealProgress = _reveal.value;
        }
      });
    if (_reveal.value < 1) _reveal.forward();
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(
      parent: _reveal,
      curve: const Interval(0, .75, curve: Curves.easeOutCubic),
    );
    final glow = CurvedAnimation(
      parent: _reveal,
      curve: const Interval(.15, 1, curve: Curves.easeOut),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ColoredBox(
        key: const ValueKey('brand-entry-view'),
        color: BrandEntryView.background,
        child: SizedBox.expand(
          child: AnimatedBuilder(
            animation: _reveal,
            builder: (context, _) => Stack(
              alignment: Alignment.center,
              children: [
                // Soft brand glow behind the logo.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          radius: .55,
                          colors: [
                            AppColors.primary.withValues(alpha: .20 * glow.value),
                            AppColors.primary.withValues(alpha: .05 * glow.value),
                            Colors.transparent,
                          ],
                          stops: const [0, .45, 1],
                        ),
                      ),
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: fade.value,
                      child: Transform.scale(
                        scale: .94 + .06 * fade.value,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primary
                                    .withValues(alpha: .28 * glow.value),
                                blurRadius: 36,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: Image.asset(
                              'assets/images/fyona_logo_light.png',
                              width: 112,
                              height: 112,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const SizedBox(
                                width: 112,
                                height: 112,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.footer != null) ...[
                      const SizedBox(height: 28),
                      widget.footer!,
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
