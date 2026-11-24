import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/services/connectivity_service.dart';

/// Animated connectivity badge for app bars: a professional pill/capsule
/// with a clear Wi-Fi signal icon and a small live status dot.
/// Green = online, amber = offline/unknown.
class ConnectivityIndicator extends StatefulWidget {
  final bool online;
  final double size;
  const ConnectivityIndicator({this.online = true, this.size = 20, super.key});

  @override
  State<ConnectivityIndicator> createState() => _ConnectivityIndicatorState();
}

class _ConnectivityIndicatorState extends State<ConnectivityIndicator>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))
      ..repeat(reverse: true);
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.online;
    final base = online ? AppColors.success : AppColors.warning;
    final t = _pulse.value;
    final s = widget.size;
    final pillH = s + 12.0;
    final pillW = s + 12.0;

    // Pulse ring behind the wifi icon (subtle, adaptive to both themes).
    final ring = 0.74 + 0.4 * t;

    return Container(
      width: pillW,
      height: pillH,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [base.withAlpha(34), base.withAlpha(12)],
        ),
        border: Border.all(color: base.withAlpha(140), width: 1.2),
        boxShadow: [
          BoxShadow(color: base.withAlpha(50), blurRadius: 6, offset: const Offset(0, 1)),
        ],
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(1),
      child: Transform.scale(
        scale: ring,
        child: Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: base.withAlpha(16),
            border: Border.all(color: base.withAlpha(90), width: 1),
          ),
          child: Center(
            child: Icon(
              online ? Icons.signal_wifi_4_bar : Icons.signal_wifi_0_bar,
              size: s - 4,
              color: base,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }
}

/// Modal dialog shown when the user tries to use an internet-required section
/// while offline. Centered + animated connectivity icon.
///
/// Returns `true` when the user taps retry and the device is online
/// (caller should refresh). Returns `false` when dismissed.
Future<bool> showOfflineDialog(
  BuildContext context, {
  String? title,
  String? message,
  String? buttonLabel,
  ConnectivityService? connectivity,
}) async {
  final l10n = AppLocalizations.of(context);
  final t = title ?? l10n.translate('noInternet');
  final m = message ?? l10n.translate('offlineSectionRequiresInternet');

  Future<bool> showOnce() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        // Scrollable so the two stacked action buttons can NEVER be clipped
        // on short screens — the back button always renders fully.
        scrollable: true,
        backgroundColor: AppColors.surface,
        title: Text(t, style: TextStyle(fontFamily: 'Cairo', fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textPrimary), textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
          const SizedBox(height: 12),
          ConnectivityIndicator(online: false, size: 40),
          const SizedBox(height: 14),
          Text(m, textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, height: 1.6, color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          Text(l10n.translate('offlineAutoSyncHint'),
              textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textDisabled)),
        ]),
        actions: [
          // Primary CTA (full-width column): Retry first, then Back below it.
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(buttonLabel ?? l10n.translate('retry'),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              // Hide — only closes this notice; the screen stays as it is.
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(ctx, false),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(l10n.translate('offlineDialogHide'),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return result ?? false;
  }

  while (true) {
    final retried = await showOnce();
    if (!retried) return false;
    // User tapped retry — check connectivity
    if (connectivity != null && connectivity.isOnline) return true;
    // Still offline — show dialog again
  }
}