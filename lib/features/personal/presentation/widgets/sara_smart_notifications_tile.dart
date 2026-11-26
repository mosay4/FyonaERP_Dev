import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../services/debt_reminder_service.dart';
import '../../services/smart_insights/sara_notice_composer.dart';
import '../../services/smart_insights/sara_smart_scheduler.dart';
import '../../services/smart_insights/sara_smart_settings.dart';
import '../../../../core/utils/time_format.dart';

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
      return formatTimeOfDay(t);
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
    // Exact time, app closed: Android 12+ needs the exact-alarm grant (an
    // inexact alarm may arrive many minutes late). Asked only when missing.
    await DebtReminderService.requestExactAlarmPermissionIfNeeded();
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
                _SaraNotifStatus(
                  key: ValueKey(
                      'saraNotifStatus-${s.effectiveMinutes}-${s.timeChangedAtMs}'),
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


/// "Next notification: …" + a real end-to-end test (native alarm in one
/// minute — arrives with the app closed or offline).
class _SaraNotifStatus extends StatefulWidget {
  const _SaraNotifStatus({super.key});

  @override
  State<_SaraNotifStatus> createState() => _SaraNotifStatusState();
}

class _SaraNotifStatusState extends State<_SaraNotifStatus> {
  DateTime? _next;
  bool _loaded = false;
  Timer? _again;

  @override
  void initState() {
    super.initState();
    _refresh();
    // The re-plan after a time change lands a moment later.
    _again = Timer(const Duration(seconds: 3), _refresh);
  }

  @override
  void dispose() {
    _again?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final n = await SaraSmartScheduler.nextDigest();
    if (!mounted) return;
    setState(() {
      _next = n;
      _loaded = true;
    });
  }

  String _label(AppLocalizations l10n) {
    final n = _next;
    if (n == null) return l10n.translate('saraSmartNotifNone');
    final time = SaraSmartNotificationsTile.formatMinutes(
        context, n.hour * 60 + n.minute);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(n.year, n.month, n.day);
    final diff = day.difference(today).inDays;
    final when = diff == 0
        ? l10n.translate('saraSmartNotifToday').replaceAll('{time}', time)
        : diff == 1
            ? l10n.translate('saraSmartNotifTomorrow').replaceAll('{time}', time)
            : '${n.day}/${n.month} $time';
    return l10n.translate('saraSmartNotifNext').replaceAll('{time}', when);
  }

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await DebtReminderService.ensureNotificationPermission();
    if (!ok) {
      messenger?.showSnackBar(
          SnackBar(content: Text(l10n.translate('saraSmartNotifBlocked'))));
      return;
    }
    await SaraSmartScheduler.scheduleTest(SaraNotice(
      kind: 'test',
      title: l10n.translate('saraSmartNotifTestTitle'),
      body: l10n.translate('saraSmartNotifTestBody'),
      route: SaraRoutes.transactions,
    ));
    messenger?.showSnackBar(
        SnackBar(content: Text(l10n.translate('saraSmartNotifTestDone'))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _loaded ? _label(l10n) : '',
              key: const Key('saraSmartNotifNext'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          TextButton.icon(
            key: const Key('saraSmartNotifTest'),
            onPressed: _test,
            icon: const Icon(Icons.notifications_active_outlined,
                size: 16, color: AppColors.primary),
            label: Text(
              l10n.translate('saraSmartNotifTest'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
