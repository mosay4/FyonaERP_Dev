import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/models/personal_models.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../../shared/services/notification_router.dart';
import '../../../shared/services/notification_service.dart';
import '../../../shared/services/reminder_codec.dart';
import 'debt_reminder_service.dart';

// ============================================================================
// RecurringReminderService — device reminders for recurring transactions.
//
// Scheduling goes through the NATIVE AlarmManager bridge
// (`scheduleReminderAlarm` / `cancelReminderAlarm` on the same
// MethodChannel the debt service uses), so alarms fire when the app is
// closed, in the background, or offline. No Firebase, no polling.
//
// The single FlutterLocalNotificationsPlugin is owned by
// NotificationService — this service never creates its own instance or
// channels (all five channels are created centrally at startup).
//
// Tapping a notification opens the recurring DETAILS page directly
// (literal-route payload with the rule id). All taps delegate to the
// central NotificationRouter. Taps arriving before the navigator exists
// (cold start) are queued centrally and flushed by the app shell.
// ============================================================================
class RecurringReminderService {
  /// Same MethodChannel name the debt service uses today.
  static const MethodChannel _native =
      MethodChannel('com.fyona.erp/alarm_native');

  static const String storeKey = 'recurring_reminders_v2';
  static const String _shownPrefsKey = 'recurring_notif_shown_v1';

  static String _detailRoute(RecurringTransaction rt) =>
      ReminderCodec.recurringRouteFor(rt.id);

  static String _storeKeyFor(String id) => 'recur_$id';

  /// Stable id per rule (String.hashCode is NOT stable across launches).
  static int stableId(String id) => ReminderCodec.stableId(id);

  /// Native alarm request code for a rule. NEVER Dart hashCode.
  static int requestCodeFor(String id) =>
      ReminderCodec.recurringRequestCode(id);

  static FlutterLocalNotificationsPlugin? get _sharedPlugin =>
      NotificationService.sharedPlugin;

  /// Legacy entry-point kept for callers: the shared plugin is owned by
  /// NotificationService, so there is nothing to initialize here.
  /// Never throws.
  static Future<void> init() async {}

  static NotificationDetails _details() {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        NotificationChannelsInfo.recurringId,
        AppLocalizations.t('recurringChannelName'),
        channelDescription: AppLocalizations.t('recurringChannelDesc'),
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
        icon: 'ic_launcher',
        color: const Color(0xFF000000),
        sound:
            const RawResourceAndroidNotificationSound('sound_2'),
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'sound_2.wav',
      ),
    );
  }

  /// Concise bilingual body from the REAL entity: name • amount • due.
  static String bodyFor(RecurringTransaction rt) {
    final rawName = rt.name.isNotEmpty
        ? rt.name
        : (rt.description?.isNotEmpty == true
            ? rt.description!
            : rt.category);
    final base = AppLocalizations.t('recurringDueBody', {
      'name': rawName,
      'amount': fmtNum(rt.amount),
      'currency': rt.currency,
    });
    final d = rt.nextDate;
    if (d == null) return base;
    return '$base • ${d.year}/${d.month}/${d.day}';
  }

  static String titleFor(RecurringTransaction rt) =>
      AppLocalizations.t('recurringDueTitle');

  /// Exact fire instant for a rule: nextDate at reminderTime (default 09:00).
  static DateTime? fireAt(RecurringTransaction rt) {
    final d = rt.nextDate;
    if (d == null) return null;
    var hour = 9;
    var minute = 0;
    final rem = rt.reminderTime;
    if (rem != null) {
      final parts = rem.split(':');
      if (parts.length == 2) {
        hour = int.tryParse(parts[0]) ?? 9;
        minute = int.tryParse(parts[1]) ?? 0;
      }
    }
    return DateTime(d.year, d.month, d.day, hour, minute);
  }

  /// Schedules the NATIVE exact alarm for a future occurrence and persists
  /// the entry in `recurring_reminders_v2` (keyed `recur_<id>`).
  /// Overwrites any previous schedule for the same rule. Never throws.
  static Future<void> schedule(RecurringTransaction rt) async {
    try {
      if (!rt.isActive) {
        await cancel(rt);
        return;
      }
      final when = fireAt(rt);
      if (when == null) return;
      final title = titleFor(rt);
      final body = bodyFor(rt);
      final route = _detailRoute(rt);
      final rc = requestCodeFor(rt.id);

      final prefs = await SharedPreferences.getInstance();
      final all = _decodeAll(prefs.getString(storeKey));
      all[_storeKeyFor(rt.id)] = ReminderCodec.buildEntry(
        millis: when.millisecondsSinceEpoch,
        title: title,
        body: body,
        kind: 'recurring',
        refId: rt.id,
        requestCode: rc,
        route: route,
      );
      await prefs.setString(storeKey, jsonEncode(all));

      await DebtReminderService.requestExactAlarmPermissionIfNeeded();
      await _native.invokeMethod('scheduleReminderAlarm', {
        'millis': when.millisecondsSinceEpoch,
        'title': title,
        'body': body,
        'kind': 'recurring',
        'refId': rt.id,
        'requestCode': rc,
        'route': route,
      });
    } catch (_) {}
  }

  static Future<void> cancel(RecurringTransaction rt) async {
    await cancelById(rt.id);
  }

  static Future<void> cancelById(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = _decodeAll(prefs.getString(storeKey));
      all.remove(_storeKeyFor(id));
      await prefs.setString(storeKey, jsonEncode(all));
    } catch (_) {}
    try {
      await _native.invokeMethod(
          'cancelReminderAlarm', {'requestCode': requestCodeFor(id)});
    } catch (_) {}
  }

  /// Re-schedules all persisted future reminders from prefs alone (no user
  /// / session needed). Called at startup and on resume. Past entries are
  /// pruned — the load-path reconcile() owns currently-due occurrences.
  /// Never throws.
  static Future<void> rescheduleAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = _decodeAll(prefs.getString(storeKey));
      if (all.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final pruned = ReminderCodec.prunePastKeys(all, now);
      for (final k in pruned) {
        all.remove(k);
      }
      for (final entry in all.values) {
        try {
          final millis = (entry['millis'] as num?)?.toInt() ?? 0;
          if (millis <= 0) continue;
          await _native.invokeMethod('scheduleReminderAlarm', {
            'millis': millis,
            'title': entry['title']?.toString() ?? '',
            'body': entry['body']?.toString() ?? '',
            'kind': 'recurring',
            'refId': entry['refId']?.toString() ?? '',
            'requestCode': (entry['requestCode'] as num?)?.toInt() ??
                requestCodeFor(entry['refId']?.toString() ?? ''),
            'route': entry['route']?.toString() ?? '',
          });
        } catch (_) {}
      }
      if (pruned.isNotEmpty) {
        await prefs.setString(storeKey, jsonEncode(all));
      }
    } catch (_) {}
  }

  /// Legacy immediate heads-up (kept for compatibility; NOT used by the
  /// load path — the native alarm is the single notifier, no duplicates).
  /// Uses the shared plugin owned by NotificationService. Never throws.
  static Future<void> showDueOnce(RecurringTransaction rt) async {
    try {
      final plugin = _sharedPlugin;
      if (plugin == null) return;
      final when = fireAt(rt) ?? DateTime.now();
      final key = '${rt.id}|${when.millisecondsSinceEpoch}';
      final prefs = await SharedPreferences.getInstance();
      final shown = prefs.getStringList(_shownPrefsKey) ?? <String>[];
      if (shown.contains(key)) return;
      await plugin.show(
        id: stableId(rt.id),
        title: titleFor(rt),
        body: bodyFor(rt),
        notificationDetails: _details(),
        payload: _detailRoute(rt),
      );
      shown.add(key);
      await prefs.setStringList(_shownPrefsKey, shown);
    } catch (_) {}
  }

  /// Legacy post-execution heads-up (kept for compatibility; NOT used by
  /// the load path). Never throws.
  static Future<void> showExecuted(RecurringTransaction rt) async {
    try {
      final plugin = _sharedPlugin;
      if (plugin == null) return;
      await plugin.show(
        id: stableId(rt.id),
        title: AppLocalizations.t('recurringAutoDoneTitle'),
        body: bodyFor(rt),
        notificationDetails: _details(),
        payload: _detailRoute(rt),
      );
    } catch (_) {}
  }

  /// Reconciles native alarms with the current list.
  ///
  /// - Every ACTIVE dated rule (reminder AND auto) gets ONE native exact
  ///   alarm at its fire instant: the single device notifier. Auto rules
  ///   still execute via the untouched sweep; the alarm only announces —
  ///   execution and notification never duplicate (same stable request
  ///   code overwritten on reschedule, shown-once key per occurrence).
  /// - Already-due occurrences get one immediate native alarm per
  ///   occurrence (shown-once key so reloads never spam).
  /// - Inactive or dateless rules get their alarm cancelled. Never throws.
  static Future<void> reconcile(List<RecurringTransaction> list) async {
    try {
      final now = DateTime.now();
      for (final rt in list) {
        try {
          if (!rt.isActive || rt.nextDate == null) {
            await cancel(rt);
            continue;
          }
          final when = fireAt(rt);
          if (when == null) continue;
          if (when.isAfter(now)) {
            await schedule(rt);
          } else {
            // Already due: single native alarm, once per occurrence.
            final key = '${rt.id}|${when.millisecondsSinceEpoch}';
            final prefs = await SharedPreferences.getInstance();
            final shown = prefs.getStringList(_shownPrefsKey) ?? <String>[];
            if (shown.contains(key)) continue;
            await schedule(rt);
            shown.add(key);
            await prefs.setStringList(_shownPrefsKey, shown);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Called by the app shell once the navigator exists: flushes taps
  /// queued centrally by the NotificationRouter.
  static void flushPendingTaps() {
    try {
      NotificationRouter.flushPending();
    } catch (_) {}
  }

  static Map<String, Map<String, dynamic>> _decodeAll(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, Map<String, dynamic>>{};
      for (final e in m.entries) {
        if (e.value is Map) {
          out[e.key] = Map<String, dynamic>.from(e.value as Map);
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }
}

/// Channel id constants (mirrors NotificationChannels without importing
/// the plugin-heavy spec into this service's public surface).
class NotificationChannelsInfo {
  static const String recurringId = 'recurring_channel';
}
