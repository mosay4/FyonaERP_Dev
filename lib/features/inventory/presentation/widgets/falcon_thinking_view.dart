import 'package:flutter/material.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';

/// The original preparation experience, without a second logo. The actual
/// Falcon is rendered once by FalconFlyingOverlay above this measured slot.
class FalconThinkingView extends StatefulWidget {
  final GlobalKey anchorKey;
  final VoidCallback onLayout;
  const FalconThinkingView({super.key, required this.anchorKey, required this.onLayout});
  @override
  State<FalconThinkingView> createState() => _ThinkingState();
}
class _ThinkingState extends State<FalconThinkingView> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(vsync: this,
      duration: const Duration(seconds: 8))..repeat();
  @override
  void dispose() { _clock.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) widget.onLayout(); });
    return Padding(padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(children: [
        SizedBox(key: widget.anchorKey, width: 60, height: 60),
        const SizedBox(width: 12),
        Expanded(child: AnimatedBuilder(animation: _clock, builder: (context, _) {
          final segment = _clock.value * 4;
          final index = segment.floor().clamp(0, 3);
          final progress = segment - index;
          final opacity = progress < .14 ? progress / .14
              : progress > .84 ? (1 - progress) / .16 : 1.0;
          return Opacity(opacity: opacity.clamp(0.0, 1.0),
            child: Transform.translate(offset: Offset(0, (1 - opacity) * 4),
              child: Text(AppLocalizations.of(context).translate(
                  ['falconThink2', 'falconThink3', 'falconLoading2', 'falconThink4'][index]),
                style: TextStyle(fontFamily: 'Cairo', fontSize: 13,
                    fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ),
          );
        })),
      ]),
    );
  }
}
