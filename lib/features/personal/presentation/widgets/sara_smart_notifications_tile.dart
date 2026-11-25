import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../services/smart_insights/sara_smart_settings.dart';

/// Personal › Profile › Preferences: "Sara's smart notifications" switch.
///
/// Off → stops ONLY Sara's periodic / smart notifications (daily digest +
/// instant spending heads-ups). System, admin, security and subscription
/// notifications are untouched (OS settings govern those).
/// On → a time row appears so the user picks the daily time (or keeps the
/// automatic "peak hour" time Sara learnt from their logging habits).
class SaraSmartNotificationsTile extends ConsumerWidget {
  /// Test seam for the time picker (defaults to Material showTimePicker).
  final Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial)?
      pickTime;

  const SaraSmartNotificationsTile({super.key, this.pickTime});

  static String formatMinutes(BuildContext context, int minutes) {
    final t = TimeOfDay(hour: (minutes ~/ 60) % 24, minute: minutes % 60);
    try {
      return MaterialLocalizations.of(context).formatTimeOfDay(t);
    } catch (_) {
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
  }

  Future<void> _chooseTime(
      BuildContext context, WidgetRef ref, SaraSmartSettings s) async {
    final initial = TimeOfDay(
      hour: (s.effectiveMinutes ~/ 60) % 24,
      minute: s.effectiveMinutes % 60,
    );
    final picked = pickTime != null
        ? await pickTime!(context, initial)
        : await showTimePicker(
            context: context,
            initialTime: initial,
            helpText: AppLocalizations.of(context)
                .translate('saraSmartNotifTime'),
          );
    if (picked == null) return;
    await ref
        .read(saraSmartSettingsProvider.notifier)
        .setMinutes(picked.hour * 60 + picked.minute);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(saraSmartSettingsProvider);
    final notifier = ref.read(saraSmartSettingsProvider.notifier);
    final timeLabel = formatMinutes(context, s.effectiveMinutes);
    final chipText = s.isAuto
        ? l10n.translate('saraSmartNotifAuto').replaceAll('{time}', timeLabel)
        : timeLabel;
    const color = AppColors.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          key: const Key('saraSmartNotifTile'),
          onTap: () => notifier.setEnabled(!s.enabled),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withAlpha(16),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: color.withAlpha(35)),
                  ),
                  child: const Center(
                    child: HugeIcon(
                      icon: HugeIcons.strokeRoundedNotification01,
                      size: 18,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.translate('saraSmartNotifTitle'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.translate('saraSmartNotifSubtitle'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const Key('saraSmartNotifSwitch'),
                  value: s.enabled,
                  activeThumbColor: AppColors.primary,
                  onChanged: (v) => notifier.setEnabled(v),
                ),
              ],
            ),
          ),
        ),
        if (s.enabled)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  key: const Key('saraSmartNotifTimeRow'),
                  onTap: () => _chooseTime(context, ref, s),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.translate('saraSmartNotifTimeDesc'),
                          key: const Key('saraSmartNotifTimeDesc'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: AppColors.primary.withAlpha(18),
                          border: Border.all(
                              color: AppColors.primary.withAlpha(110)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule_rounded,
                                size: 16, color: AppColors.primary),
                            const SizedBox(width: 6),
                            Text(
                              chipText,
                              key: const Key('saraSmartNotifTimeLabel'),
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (!s.isAuto)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      key: const Key('saraSmartNotifUseAuto'),
                      onPressed: () => notifier.setMinutes(null),
                      child: Text(
                        l10n.translate('saraSmartNotifUseAuto'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11.5,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
