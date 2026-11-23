import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';

class TrialCountdownTimer extends StatefulWidget {
  final Duration remaining;
  final VoidCallback? onDismiss;

  const TrialCountdownTimer({
    super.key,
    required this.remaining,
    this.onDismiss,
  });

  @override
  State<TrialCountdownTimer> createState() => _TrialCountdownTimerState();
}

class _TrialCountdownTimerState extends State<TrialCountdownTimer>
    with SingleTickerProviderStateMixin {
  late Timer _timer;
  late int _totalSeconds;
  late AnimationController _animCtrl;
  late Animation<double> _pulseAnim;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _totalSeconds = widget.remaining.inSeconds;
    _animCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut),
    );
    _animCtrl.repeat(reverse: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _totalSeconds > 0) {
        setState(() => _totalSeconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed || _totalSeconds <= 0) return const SizedBox.shrink();

    final hours = _totalSeconds ~/ 3600;
    final minutes = (_totalSeconds ~/ 60) % 60;
    final seconds = _totalSeconds % 60;

    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: ScaleTransition(
        scale: _pulseAnim,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.primary.withAlpha(40),
                Color(0xFF1A0A10).withAlpha(230),
                AppColors.primaryDark.withAlpha(50),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.primary.withAlpha(60),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withAlpha(30),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Gift icon (no rotation animation to avoid debug assertion)
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.primary, AppColors.primaryDark],
                  ),
                  boxShadow: [
                    BoxShadow(color: AppColors.primary.withAlpha(60), blurRadius: 8),
                  ],
                ),
                child: TwoToneIcon(
                  data: TwoToneIcons.gift,
                  size: 18,
                  outlineColor: Colors.white,
                ),
              ),
              const SizedBox(width: 12),

              // Countdown digits
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _DigitBox(value: hours.toString().padLeft(2, '0'), label: AppLocalizations.of(context).translate('hour')),
                    _Separator(),
                    _DigitBox(value: minutes.toString().padLeft(2, '0'), label: AppLocalizations.of(context).translate('minute')),
                    _Separator(),
                    _DigitBox(value: seconds.toString().padLeft(2, '0'), label: AppLocalizations.of(context).translate('second')),
                  ],
                ),
              ),

              // Dismiss button
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _dismissed = true);
                  widget.onDismiss?.call();
                },
                child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: TwoToneIcon(
                    data: TwoToneIcons.close,
                    size: 14,
                    outlineColor: Colors.white.withAlpha(150),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  DIGIT BOX — 3D number block
// ════════════════════════════════════════════════════════════
class _DigitBox extends StatelessWidget {
  final String value;
  final String label;

  const _DigitBox({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 3D digit container
        Container(
          width: 40,
          height: 36,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF2A1520),
                Color(0xFF1A0A10),
              ],
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.primary.withAlpha(40),
              width: 0.5,
            ),
            boxShadow: [
              // Top highlight (3D light)
              BoxShadow(
                color: AppColors.primary.withAlpha(20),
                blurRadius: 0,
                offset: const Offset(0, -1),
              ),
              // Bottom shadow (3D depth)
              BoxShadow(
                color: Colors.black.withAlpha(60),
                blurRadius: 4,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            value,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 18),
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
              height: 1.0,
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 8),
            fontWeight: FontWeight.w500,
            color: Colors.white.withAlpha(120),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════
//  SEPARATOR — blinking colon
// ════════════════════════════════════════════════════════════
class _Separator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        ':',
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 18),
          fontWeight: FontWeight.w700,
          color: AppColors.primary.withAlpha(150),
        ),
      ),
    );
  }
}
